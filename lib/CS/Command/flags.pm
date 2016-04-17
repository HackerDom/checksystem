package CS::Command::flags;
use Mojo::Base 'Mojolicious::Command';

has description => 'Get flags';

sub run {
  my $self = shift;
  my $app  = $self->app;

  my $scoreboard_info = $app->model('score')->scoreboard_info;
  $app->pg->pubsub->json('scoreboard')->listen(scoreboard => sub { $scoreboard_info = $_[1] });

  Mojo::IOLoop->server(
    {port => $app->config->{cs}{flags}{port}} => sub {
      my ($loop, $stream, $id, $do, $lock) = @_;
      return $stream->close unless $app->model('util')->game_status == 1;

      my $ip      = $stream->handle->peerhost;
      my $team_id = $app->model('util')->team_id_by_address($ip);
      return $stream->write("Your IP address $ip is unknown\n" => sub { $stream->close }) unless $team_id;

      $app->log->info("[flags] [$id] new stream from $ip ($team_id)");

      my $buffer = '';
      $stream->timeout($app->config->{cs}{flags}{timeout});

      $stream->on(error => sub { $app->log->error("[flags] [$id] stream error: $_[1]") });
      $stream->on(close => sub { undef $do; $app->log->info("[flags] [$id] close stream") });
      $stream->on(read  => sub { $buffer .= $_[1]; $do->(); });

      $stream->write("Enter your flags, finished with newline (or empty line to exit)\n");

      $do = sub {
        return if $lock;
        if ((my $index = index $buffer, "\n") != -1) {
          my $flag = substr $buffer, 0, $index + 1, '';
          $flag =~ s/\r?\n$//;
          return $stream->write("Goodbye!\n" => sub { $stream->close }) unless length $flag;
          return $stream->write("Invalid flag\n") unless $app->model('flag')->validate($flag);

          $lock = 1;
          $app->model('flag')->accept(
            $team_id, $flag,
            $scoreboard_info,
            sub {
              my $msg = $_[0]->{ok} ? $_[0]->{message} : $_[0]->{error};
              $app->log->info("[flags] [$id] input flag '$flag' result '$msg'");
              $stream->write("$msg\n");
              undef $lock;
              $do->() if $do;
            }
          );
        }
      };
    }
  );
  Mojo::IOLoop->start;
}

1;
