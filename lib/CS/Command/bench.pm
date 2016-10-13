package CS::Command::bench;
use Mojo::Base 'Mojolicious::Commands';

has description => 'Some staff for perfomance tests big game setup';
has message     => sub { shift->extract_usage . "\nCommands:\n" };
has namespaces  => sub { ['CS::Command::bench'] };

sub help { shift->run(@_) }

1;

=encoding utf8

=head1 NAME

CS::Command::bench - bench command

=head1 SYNOPSIS

  Usage: APPLICATION bench COMMAND [OPTIONS]

=head1 DESCRIPTION

=cut
