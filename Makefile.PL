use inc::Module::Install;
use Config;

name     'IO-Pty-HalfDuplex';
all_from 'lib/IO/Pty/HalfDuplex.pm';

requires 'IO::Pty';
requires 'Time::HiRes';

# This is slightly evil.  All the XS in IO-Pty-HalfDuplex is _optional_,
# so we try to build it, and remove it from the Makefile if it fails.

my @chunks = qw(ptrace sysctl);
my @object;
my @c;
my @using;
my $xs = '';

print <<NOTE ;
Makefile.PL is now attempting to determine which XS-based IO::Pty::HalfDuplex
backends will compile on your system ...

NOTE

open OLD_STDOUT, ">&STDOUT";
open OLD_STDERR, ">&STDERR";

open STDOUT, ">configure.log";
open STDERR, ">&STDOUT";

print STDOUT <<NOTE ;
These are the results of configuration probes; any errors here will not
prevent IO::Pty::HalfDuplex from building.

NOTE

makemaker_args(OBJECT => join(" ", map { "$_.o" } @chunks));
WriteAll;

for my $chunk (@chunks) {
    my $src = "$chunk.c";
    my $obj = "$chunk$Config{_o}";

    unlink $obj;  # no error check

    print "Trying to build $obj ...\n";

    if (system("make $obj") == 0 && -s $obj) {
        # Oooh, it works
        local $/;
        open FRAGMENT, "$chunk.xsf" or die
            "Failed to open fragment $chunk.xsf: $!";
        $xs .= "\n" . <FRAGMENT>;
        close FRAGMENT;

        push @object, $obj;
        push @c, $src;
        push @using, $chunk;
    }
}

open STDOUT, ">&OLD_STDOUT"; close OLD_STDOUT;
open STDERR, ">&OLD_STDERR"; close OLD_STDERR;

print "Done.  We are building ",
    (@using ? "with: " . join(", ", @using) : "without XS") . ".\n";

if ($xs) {
    open XS, ">HalfDuplex.xs" or
        die "Failed to open xs-file for output: $!";
    print XS <<HEADER ;
/* Automatically generated from *.xsf by Makefile.PL */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = IO::Pty::HalfDuplex  PACKAGE = IO::Pty::HalfDuplex

PROTOTYPES: ENABLE

HEADER
    print XS $xs;
    close XS or die "Failed to close xs-file: $!";
    push @object, "HalfDuplex$Config{_o}";
    push @c, "HalfDuplex.c";
} else {
    unlink "HalfDuplex.xs";
}

makemaker_args(OBJECT => join(" ",@object), C => \@c);
WriteAll;

