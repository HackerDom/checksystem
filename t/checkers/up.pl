#!/usr/bin/perl

my $command = shift;
if ($command eq 'info') {
  print "vulns: 1:1:2\npublic_flag_description: user profile\n";
} else {
  print '{"public_flag_id":"911","password":"sEcr3t"}';
}
exit 101;
