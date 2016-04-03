package CS::Command::flags;
use Mojo::Base 'Mojolicious::Command';

has description => 'Get flags';

sub run {
  my $self = shift;
  my $app  = $self->app;

  Mojo::IOLoop->server(
    {port => $app->config->{cs}{flags}{port}} => sub {
      my ($loop, $stream, $id) = @_;
      return $stream->close unless $app->model('util')->game_status == 1;

      my $ip      = $stream->handle->peerhost;
      my $team_id = $app->model('util')->team_id_by_address($ip);
      return $stream->write("Your IP address $ip is unknown\n" => sub { $stream->close }) unless $team_id;

      $app->log->info("[flags] [$id] new stream from $ip ($team_id)");

      $stream->timeout($app->config->{cs}{flags}{timeout});
      $stream->on(error   => sub { $app->log->error("[flags] [$id] stream error: $_[1]") });
      $stream->on(timeout => sub { $app->log->error("[flags] [$id] timeout") });
      $stream->on(close   => sub { $app->log->info("[flags] [$id] close stream") });

      $stream->write("Your team id is $team_id\n");
      $stream->write("Enter your flags, finished with newline (or empty line to exit)\n");

      my $buffer = '';
      $stream->on(
        read => sub {
          my ($stream, $bytes) = @_;
          $buffer .= $bytes;

          while ((my $index = index $buffer, "\n") != -1) {
            my $flag = substr $buffer, 0, $index + 1, '';
            $flag =~ s/\r?\n$//;
            return $stream->write("Goodbye!\n" => sub { $stream->close }) unless length $flag;
            return $stream->write("Invalid flag\n") unless $app->model('flag')->validate($flag);

            $app->log->info("[flags] [$id] input flag: $flag");
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
