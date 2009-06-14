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

WriteAll(OBJECT => [ map { "src/$_.o" } @chunks ]);

for my $chunk (@chunks) {
    my $src = "src/$chunk.c";
    my $obj = "src/$chunk$Config{_o}";

    unlink $obj;  # no error check

    print "Trying to build $obj ...\n";

    if (system("make $obj") == 0 && -s $obj) {
        # Oooh, it works
        local $/;
        open FRAGMENT, "src/$_.xsf" or die
            "Failed to open fragment src/$_.xsf: $!";
        $xs .= <FRAGMENT>;
        close FRAGMENT;

        push @object, $obj;
    }
}

if ($xs) {
    open XS, ">HalfDuplex.xs" or die "Failed to open xs-file for output: $!";
    print XS "/* Automatically generated from src/*.xsf by Makefile.PL */\n";
    print XS $xs;
    close XS or die "Failed to close xs-file: $!";
} else {
    unlink "HalfDuplex.xs";
}

WriteAll(OBJECT => \@object);

