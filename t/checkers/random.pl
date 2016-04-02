#!/usr/bin/perl

print "vulns: 1:2\n" and exit 101 if (shift // '') eq 'info';
exit(101 + int rand 4);
