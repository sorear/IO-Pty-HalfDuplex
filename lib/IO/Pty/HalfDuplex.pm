#!/usr/bin/env perl
# vim: fdm=marker sw=4 et
package IO::Pty::HalfDuplex;
# Notes on design {{{
# IO::Pty::HalfDuplex operates by mimicing a job-control shell.  A process
# is done sending data when it calls read, which we notice because it
# results in Stopped (tty input).  So far, fairly simple.  Complications
# arise because of races, and also because shells are required to run in
# the managed tty, and be the parent of the process; this forces us to use
# a stub process and simple IPC.
# }}}
# POD header {{{

=head1 NAME

IO::Pty::HalfDuplex - Treat interactive programs like subroutines

=head1 SYNOPSIS

    use IO::Pty::HalfDuplex;

    my $pty = IO::Pty::HalfDuplex->new;

    $pty->spawn("nethack");

    $pty->read;
    # => "\nNetHack, copyright...for you? [ynq] "

    $pty->write("nvd");
    $pty->read;

    # => "... Velkommen sorear, you are a lawful dwarven Valkyrie.--More--"

=head1 DESCRIPTION

C<IO::Pty::HalfDuplex> is designed to perform impedence matching between
driving programs which expect commands and responses, and driven programs
which use a terminal in full-duplex mode.  In this vein it is somewhat like
I<expect>, but less general and more robust (but see CAVEATS below).

This module is used in object-oriented style.  IO::Pty::HalfDuplex objects
are connected to exactly one system pseudoterminal, which is allocated on
creation; input and output are done using methods.  The interface is
deliberately kept similar to Jesse Luehrs' L<IO::Pty::Easy> module; notable
incompatibilities from the latter are:

=over

=item *

The spawn() method reports failure to exec inline, on output followed
by an exit.  I see no reason why exec failures should be different from post-exec failures such as "dynamic library not found", and it considerably simplifes the code.

=item *

write() does not immediately write anything, but merely queues data to be released all at once by read().  It does not have a timeout parameter.

=item *

read() should generally not be passed a timeout, as it finds the end of output automatically.

=item *

The two-argument form of kill() interprets its second argument in the opposite sense.

=back

=head1 METHODS

=cut

# }}}
# Imports {{{
use strict;
use warnings;
use IO::Pty::HalfDuplex::Shell;
use POSIX qw(:unistd_h :sys_wait_h :signal_h);
use Carp;
use IO::Pty;
use Time::HiRes qw(time);
our $VERSION = '0.01';
our $_infinity = 1e1000;
# }}}
# new {{{
# Most of this is handled by IO::Pty, thankfully

=head2 new()

Allocates and returns a IO::Pty::HalfDuplex object.

=cut

sub new {
    my $class = shift;
    my $self = {
        # options
        buffer_size => 8192,
        @_,

        # state
        pty => undef,
        active => 0,
        exit_code => undef,
    };

    bless $self, $class;

    $self->{pty} = new IO::Pty;

    return $self;
}
# }}}
# spawn {{{

=head2 spawn(I<LIST>)

Starts a subprocess under the control of IO::Pty::HalfDuplex.  I<LIST> may be
a single string or list of strings as per Perl exec.

=cut

sub spawn {
    my $self = shift;
    my $slave = $self->{pty}->slave;

    croak "Attempt to spawn a subprocess when one is already running"
        if $self->is_active;

    pipe (my $p1r, my $p1w) || croak "Failed to create a pipe";
    pipe (my $p2r, my $p2w) || croak "Failed to create a pipe";

    $self->{data_pipe} = $p1r;
    $self->{ctl_pipe} = $p2w;

    defined ($self->{shell_pid} = fork) || croak "fork: $!";

    unless ($self->{shell_pid}) {
        close $p1r;
        close $p2w;
        $self->{pty}->make_slave_controlling_terminal;
        close $self->{pty};
        $slave->set_raw;
        # reopen the standard file descriptors in the child to point to the
        # pty rather than wherever they have been pointing during the script's
        # execution
        open(STDIN,  "<&" . $slave->fileno)
            or carp "Couldn't reopen STDIN for reading";
        open(STDOUT, ">&" . $slave->fileno)
            or carp "Couldn't reopen STDOUT for writing";
        open(STDERR, ">&" . $slave->fileno)
            or carp "Couldn't reopen STDERR for writing";
        close $slave;

        IO::Pty::HalfDuplex::Shell->new(data_pipe => $p1w, ctl_pipe => $p2r,
            command => [@_]);
    }

    close $p1w;
    close $p2r;
    $self->{pty}->close_slave;
    $self->{pty}->set_raw;

    my ($rcpid);
    my $syncd = sysread($self->{info_pipe}, $rcpid, 4);

    unless ($syncd == 4) {
        croak "Cannot sync with child: $!";
    }
    $self->{slave_pgid} = unpack "N", $rcpid;

    $self->{read_buffer} = $self->{write_buffer} = '';
    $self->{active} = $self->{waiting} = 1;
    $self->{timeout} = $self->{exit_code} = $self->{exit_sig} = undef;

    syswrite $p2w, "w" . pack "d", $_infinity;
}
# }}}
# I/O on shell pipes {{{
# Process a wait result from the shell
sub _handle_info_read {
    my $self = shift;

    my $ibuf;

    $self->{waiting} = 0;

    my $ret = sysread $self->{info_pipe}, $ibuf, 1;

    if ($ret == 0) {
        # Suprise EOF means the shell must have crashed
        $self->{active} = 0;
        $self->{exit_code} = undef;
    } elsif ($ibuf eq 'd') {
        sysread $self->{info_pipe}, $ibuf, 2;

        $self->{active} = 0;
        @{$self}{"exit_sig","exit_code"} = unpack "CC", $ibuf;
    } elsif ($ibuf eq 'r') {
    } elsif ($ibuf eq 't') {
        die "timeout\n";
    }
}

sub _handle_pty_write {
    my ($self, $ref) = @_;

    my $ct = syswrite $self->{pty}, $self->{write_buffer}
        or die "write(pty): $!";

    $self->{write_buffer} = substr($self->{write_buffer}, $ct);
}

sub _handle_pty_read {
    my ($self) = @_;

    sysread $self->{pty}, $self->{read_buffer}, $self->{buffer_size},
        length $self->{read_buffer} or die "read(pty): $!";
}
# }}}
# Read internals {{{
# A little something to make all these select loops nicer, NOT A METHOD
sub _select_loop {
    my $block = shift;
    my $pred = shift;

    while ($pred->()) {
        my %mask = ('r' => '', 'w' => '', 'x' => '');

        for (@_) {
            vec($mask{$_->[1]}, fileno($_->[0]), 1) = 1;
        }

        last unless select($mask{r}, $mask{w}, $mask{x}, $block ? undef : 0);

        for (@_) {
            $_->[2]() if vec($mask{$_->[1]}, fileno($_->[0]), 1);
        }
    }
}

# While the slave is active, send and receive data until either the write
# buffer is empty or the kernel write buffer is full.  In either case, the
# slave is reading, dead, or busy; wait to find out which.
# 
# While the shell is waiting, read data to avoid a deadlock threat; the shell
# will not return until the kernel write buffer is empty or the slave is dead,
# in the latter case or if our write buffer is empty we can return, otherwise
# we start again.

sub _process_wait {
    my ($self) = shift;

    croak "_process_wait should only be called when the slave is waiting!"
        unless $self->{active} && $self->{waiting};

    _select_loop 1 => sub{ $self->{waiting} },
        [ $self->{info_pipe}, r => sub { $self->_handle_info_read() } ],
        [ $self->{pty}, r       => sub { $self->_handle_pty_read() } ];
}

# Send as much data as possible
sub _process_send {
    my ($self) = shift;

    _select_loop 0 => sub{ $self->{write_buffer} ne '' },
        [ $self->{pty}, r => sub { $self->_handle_pty_read() } ],
        [ $self->{pty}, w => sub { $self->_handle_pty_write() } ];
}

sub _stop_process {
    my $self = shift;
    syswrite $self->{ctl_pipe}, "-w" . pack ("d", $self->{timeout});
    $self->{waiting} = 1;
}

sub _start_process {
    syswrite shift->{ctl_pipe}, "+";
}
# }}}
# I/O operations {{{

=head2 recv([I<TIMEOUT>])

Reads all output that the subprocess will send.  If I<TIMEOUT> is specified and
the process has not finished writing, undef is returned and the existing output
is retained in the read buffer for use by subsequent recv calls.

I<TIMEOUT> is in (possibly fractional) seconds.

=cut

sub recv {
    my ($self, $timeout) = @_;

    if (! $self->is_active) {
        carp "Reading from dead slave";
        return;
    }

    $self->{timeout} = ($timeout || $_infinity) + time;

    do  {
        if (!$self->{waiting}) {
            $self->_start_process();
            $self->_process_send();
            $self->_stop_process();
        }

        eval { $self->_process_wait(); };
        return undef if $@ eq "timeout\n";
        die $@ if $@;
    } while ($self->{write_buffer} ne '' && $self->{active});

    if (!$self->{active}) {
        # Reap the shell
        waitpid($self->{shell_pid}, 0);

        if (!defined $self->{exit_code}) {
            # Get the shell crash code
            $self->{exit_sig}  = WIFSIGNALED($?) ? WTERMSIG($?) : 0;
            $self->{exit_code} = WIFEXITED($?) ? WEXITCODE($?) : 0;
        }
    }

    my $t = $self->{read_buffer};
    $self->{read_buffer} = '';
    $t;
}

=head2 write(I<TEXT>)

Appends I<TEXT> to the write buffer to be sent on the next recv.

=cut

sub write {
    my ($self, $text) = @_;

    if (! $self->is_active) {
        carp "Writing to dead slave";
        return;
    }

    $self->{write_buffer} .= $text;
}

=head2 is_active()

Returns true if the slave process currently exists.

=cut

sub is_active {
    my $self = shift;

    return $self->{active};
}

sub _wait_for_inactive {
    my $self = shift;
    my $targ = (shift || $_infinity) + time;

    do {
        $self->read($targ - time);
    } while ($targ > time && $self->is_active);

    !$self->is_active;
}
# }}}
# kill() {{{
=head2 kill()

Sends a signal to the process currently running on the pty (if any). Optionally blocks until the process dies.

C<kill()> takes an even number of arguments.  They are interpreted as pairs of signals and a length of time to wait after each one, or 0 to not wait at all.  Signals may be in any format that the Perl C<kill()> command recognizes.  Any output generated while waiting is discarded.

Returns 1 immediately if the process exited during a wait, 0 if it was successfully signalled but did not exit, and undef if the signalling failed.

C<kill()> (with no arguments) is equivalent to C<kill(TERM => 3, KILL => 3)>.

=cut

sub kill {
    my $self = shift;

    if (@_ < 2) { @_ = (TERM => 3, KILL => 3); }

    return 1 if !$self->is_active;

    while (@_ >= 2) {
        my ($sig, $tme) = splice @_, 0, 2;
        
        kill $sig => -$self->{slave_pgid}
            or return undef;

        $tme = defined $tme ? $tme : $_infinity;

        if ($tme && $self->_wait_for_inactive($tme)) {
            return 1;
        }
    }

    return 0;
}
# }}}
# close() {{{

=head2 close()

Kills any subprocesses and closes the pty. No other operations are valid after this call.

=over 4

=back

=cut

sub close {
    my $self = shift;

    $self->kill;
    close $self->{pty};
    $self->{pty} = undef;
}
# }}}
# documentation tail {{{

1;

__END__

=head1 CAVEATS

C<IO::Pty::HalfDuplex> is implemented using POSIX job control, and as such it
requires foreground access to a controlling terminal.  Programs which interfere
with process hierarchies, such as C<strace -f>, will break
C<IO::Pty::HalfDuplex>.

Certain ioctls used by terminal-aware programs are treated as reads by POSIX
job control.  If this is done while the input buffer is empty, it may cause a
spurious stop by C<IO::Pty::HalfDuplex>.  Under normal circumstances this
manifests as a need to transmit at least one character before the starting
screen is displayed.

C<IO::Pty::HalfDuplex> sends many continue signals to the slave process.  If
the slave catches SIGCONT, you may see many spurious redraws.  If possible,
modify your child to handle SIGTSTP instead.

C<IO::Pty::HalfDuplex> won't work with programs that rely on non-blocking
input or generate output in other threads after blocking for input in one.

=head1 AUTHOR

Stefan O'Rear, C<< <stefanor@cox.net> >>

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-io-halfduplex at rt.cpan.org>, or browse
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=IO-HalfDuplex>.

=head1 COPYRIGHT AND LICENSE

Copyright 2008-2009 Stefan O'Rear.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# }}}
