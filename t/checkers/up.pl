#!/usr/bin/perl

my $command = shift;
if ($command eq 'info') {
  print 'vulns: 1:1:2';
} else {
  print '911';
}
exit 101;
