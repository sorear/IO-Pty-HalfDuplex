use inc::Module::Install;

name     'IO-HalfDuplex';
all_from 'lib/IO/HalfDuplex.pm';

build_requires 'Test::More';

WriteAll;

