use strict;
use warnings;

use Test::More;

use File::Spec;
require File::Spec::Win32;
@File::Spec::ISA = qw(File::Spec::Win32); # pretend to be Win32
use ExtUtils::Depends;

sub make_fake {
  my ($name, $path) = @_;
  my @parts = split /::/, $name;
  push @parts, qw(Install Files);
  my $req_name = join('/', @parts).".pm";
  $INC{$req_name} = "$path/$req_name";
}
make_fake('FakeUNC', '//server/share/file');
my $hash = ExtUtils::Depends::load('FakeUNC');
my $s = '[\\/]';
like $hash->{instpath}, qr/^${s}${s}server${s}share${s}file${s}FakeUNC${s}Install${s}?$/, 'preserves UNC server';

done_testing;
