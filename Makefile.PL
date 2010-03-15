use inc::Module::Install;
name 'Net-Google-DocumentsList';
all_from 'lib/Net/Google/DocumentsList.pm';

# requires '';
requires_any_moose(
    moose => '0.56',
    mouse => '0.51',
);
requires 'Net::Google::DataAPI' => '0.17';
requires 'namespace::autoclean';
requires 'XML::Atom';
requires 'File::Slurp';
requires 'MIME::Types';
requires 'URI';
requires 'URI::Escape';
requires 'DateTime::Format::Atom';
requires 'String::CamelCase' => '0.02';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
build_requires 'File::BOM';
auto_include;
auto_set_repository;
WriteAll;