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
my $xs = '';

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
    }
}

if ($xs) {
    open XS, ">HalfDuplex.xs" or
        die "Failed to open xs-file for output: $!";
    print XS <<HEADER ;
/* Automatically generated from *.xsf by Makefile.PL */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = HalfDuplex  PACKAGE = IO::Pty::HalfDuplex

PROTOTYPES: ENABLE

HEADER
    print XS $xs;
    close XS or die "Failed to close xs-file: $!";
} else {
    unlink "HalfDuplex.xs";
}

makemaker_args(OBJECT => join(" ","HalfDuplex$Config{_o}",@object));
WriteAll;

