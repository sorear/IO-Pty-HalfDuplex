#!/usr/bin/env perl
package IO::Pty::HalfDuplex;
use strict;
use warnings;
use POSIX qw(:unistd_h :sys_wait_h :signal_h);
use IO::Pty::Easy;

our $VERSION = '0.01';

sub _slave {
    my ($inpipe, $outpipe, @args) = @_;

    $SIG{'CHLD'} = sub { };
    $SIG{'TTOU'} = $SIG{'TTIN'} = $SIG{'TSTP'} = 'IGNORE';

    setpgrp $$, $$;

    POSIX::tcsetpgrp(0, $$)
        or die "cannot tcsetpgrp: $!\n";

    my $cpid;

    if (!defined ($cpid = fork)) {
        die "Cannot fork: $!\n";
    }

    if (!$cpid) {
        # Child

        $SIG{'CHLD'} = $SIG{'TTOU'} = $SIG{'TTIN'} = $SIG{'TSTP'} = 'DEFAULT';

        setpgrp;

        exec @args;
        die "Cannot exec(@ARGV): $!";
    }

    while (1) {
        # Wait until the slave blocks (or dies) {{{

        my $stat;
        do {
            waitpid($cpid, WUNTRACED) || die "wait failed: $!\n";
            $stat = ${^CHILD_ERROR_NATIVE};
        } while (WIFSTOPPED($stat) && WSTOPSIG($stat) != SIGTTIN
            && WSTOPSIG($stat) != SIGTTOU);

        if (!WIFSTOPPED($stat)) {
            # Oh, it's dead.

            syswrite $outfh, "\0";
            exit WEXITSTATUS($stat);
        }

        # }}}
        # Slave is blocked.  Is there any unread input? {{{
        my $more;
        {
            my $ivec = "\1";

            ($more = select $ivec, undef, undef, 0) >= 0 or
                die "select failed: $!\n";
        }

        # }}}
        # None?  OK, tell our user and get the next block of input {{{

        if (!$more && WSTOPSIG($stat) == SIGTTIN) {
            my $null;
            syswrite $outfh, "\0";
            sysread $infh, $null, 1;
        }

        # }}}
        # Step the slave {{{

        POSIX::tcsetpgrp 0, $cpid;
        kill SIGCONT, $cpid;

        # Yuk.  We need the slave to actually be scheduled and read data...
        select undef, undef, undef, 0.005;

        kill SIGSTOP, $cpid;
        POSIX::tcsetpgrp 0, $$;
        kill SIGCONT, $cpid;

        # }}}
    }
}

=head1 NAME

ristub - the remote interactive stub

=head1 SYNOPSIS

ristub INFD OUTFD CMD [ARGS...]

=head1 DESCRIPTION

C<ristub> is a program designed to perform impedence matching between driving
programs which expect commands and responses, and driven programs which
use a terminal in full-duplex mode.  In this vein it is somewhat like
I<expect>, but less general and more robust.

C<ristub> is not suitible for interactive use.  To use C<ristub>, you need to
create two pipes and pass file descriptors as the first and second arguments.
When the child program is finished sending data, a single 0 byte will be sent
to the pipe OUTFD.  When you are finished sending input, you should send a
single byte on the pipe INFD.

=head1 CAVEATS

C<ristub> is implemented using POSIX job control, and as such it requires
foreground access to a controlling terminal.  Programs which interfere with
process hierarchies, such as B<strace -f>, will break C<ristub>.

Certain ioctls used by terminal-aware programs are treated as reads by POSIX
job control.  If this is done while the input buffer is empty, it may cause
a spurious stop by C<ristub>.  Under normal circumstances this manifests as
a need to transmit at least one character before the starting screen is
displayed.

Most of the design and implementation of C<ristub> was executed between
midnight and 2:00 AM.  You have been warned.

=cut


1;

__END__

=head1 NAME

IO::HalfDuplex - ??

=head1 SYNOPSIS

    use IO::HalfDuplex;

=head1 DESCRIPTION



=head1 AUTHOR

Stefan O'Rear, C<< <stefanor@cox.net> >>

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-io-halfduplex at rt.cpan.org>, or browse
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=IO-HalfDuplex>.

=head1 COPYRIGHT AND LICENSE

Copyright 2008 Stefan O'Rear.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

