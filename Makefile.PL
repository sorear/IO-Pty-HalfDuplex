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
my @clean;
my $xs = '';

makemaker_args(OBJECT => join(" ", map { "src/$_$Config{_o}" } @chunks));
WriteAll;

for my $chunk (@chunks) {
    my $src = "src/$chunk.c";
    my $obj = "src/$chunk$Config{_o}";

    unlink $obj;  # no error check

    print "Trying to build $obj ...\n";

    if (system("make $obj") == 0 && -s $obj) {
        # Oooh, it works
        local $/;
        open FRAGMENT, "src/$chunk.xsf" or die
            "Failed to open fragment $chunk.xsf: $!";
        $xs .= <FRAGMENT>;
        close FRAGMENT;

        push @object, $obj;
    }
}

if ($xs) {
    open XS, ">src/HalfDuplex.xs" or
        die "Failed to open xs-file for output: $!";
    print XS <<HEADER ;
/* Automatically generated from src/ *.xsf by Makefile.PL */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = HalfDuplex  PACKAGE = IO::Pty::HalfDuplex

PROTOTYPES: ENABLE

HEADER
    print XS $xs;
    close XS or die "Failed to close xs-file: $!";
    makemaker_args(
        OBJECT => join(q{ }, @object, "src/HalfDuplex$Config{_o}"),
        XS     => { 'src/HalfDuplex.xs' => 'src/HalfDuplex.c' },
        clean  => { FILES => join(q{ }, @object, "src/HalfDuplex$Config{_o}",
                "src/HalfDuplex.xs", "src/HalfDuplex.c") }
    );
} else {
    unlink "src/HalfDuplex.xs";
}

WriteAll;

# The following copied from Class::MOP, and allows .c files in subdirs
package MY;

use Config;

sub const_cccmd {
    my $ret = shift->SUPER::const_cccmd(@_);
    return q{} unless $ret;

    if ($Config{cc} =~ /^cl\b/i) {
        warn 'you are using MSVC... my condolences.';
        $ret .= ' /Fo$@';
    }
    else {
        $ret .= ' -o $@';
    }

    return $ret;
}
