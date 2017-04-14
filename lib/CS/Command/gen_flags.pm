package CS::Command::gen_flags;
use Mojo::Base 'Mojolicious::Command';

has description => 'Generate some flags';

sub run {
  my $app = shift->app;
  my ($team_id, $service_id, $vuln_id, $count) = @_;

  for (1..$count) {
    my $flag = $app->model('flag')->create;
    say "$flag->{data},$flag->{id},0,$team_id,$service_id,$vuln_id";
  }
}

1;
