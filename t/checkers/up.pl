#!/usr/bin/perl

my $command = shift;
if ($command eq 'info') {
  print "vulns: 1:1:2\npublic_flag_description: user profile\n";
} else {
  print '911';
}
exit 101;
