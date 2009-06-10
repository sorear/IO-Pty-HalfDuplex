use inc::Module::Install;

name     'IO-Pty-HalfDuplex';
all_from 'lib/IO/Pty/HalfDuplex.pm';

requires 'IO::Pty';
requires 'Time::HiRes';

WriteAll;

