package CS::Command::flags;
use Mojo::Base 'Mojolicious::Command';

has description => 'Get flags';

sub run {
  my $self = shift;
  my $app  = $self->app;

  Mojo::IOLoop->server(
    {port => $app->config->{cs}{flags}{port}} => sub {
      my ($loop, $stream) = @_;
      $stream->timeout($app->config->{cs}{flags}{timeout});

      my $ip      = $stream->handle->peerhost;
      my $team_id = $app->model('util')->team_id_by_address($ip);
      return $stream->write("Your IP address $ip is unknown\n" => sub { $stream->close }) unless $team_id;

      $stream->write(
        "Your team id is $team_id\nEnter your flags, finished with newline (or empty line to exit)\n");

      my $buffer = '';
      $stream->on(
        read => sub {
          my ($stream, $bytes) = @_;
          $buffer .= $bytes;

          while ((my $index = index $buffer, "\n") != -1) {
            my $flag = substr $buffer, 0, $index + 1, '';
            $flag =~ s/\r?\n$//;
            return $stream->write("Goodbye!\n" => sub { $stream->close }) unless length $flag;

            my $result = $app->model('flag')->accept($team_id, $flag);
            $stream->write($result->{ok} ? "Accepted\n" : "$result->{error}\n");
          }
        }
      );
    }
  );
  Mojo::IOLoop->start;
}

1;
