use inc::Module::Install;

name     'IO-Pty-HalfDuplex';
all_from 'lib/IO/Pty/HalfDuplex.pm';

build_requires 'Test::More';

WriteAll;

