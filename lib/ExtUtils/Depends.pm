#
# $Header$
#

package ExtUtils::Depends;

use strict;
use warnings;
use Carp;
use File::Spec;
use Data::Dumper;

our @VERSION = 0.200;

sub new {
	my ($class, $name, @deps) = @_;
	my $self = bless {
		name => $name,
		deps => {},
		inc => [],
		libs => [],

		pm => {},
		typemaps => [],
		xs => [],
		c => [],
	}, $class;

	$self->add_deps (@deps);

	# attempt to load these now, so we'll find out as soon as possible
	# whether the dependencies are valid.  we'll load them again in
	# get_makefile_vars to catch any added between now and then.
	$self->load_deps;

	return $self;
}

sub add_deps {
	my $self = shift;
	foreach my $d (@_) {
		$self->{deps}{$d} = undef
			unless $self->{deps}{$d};
	}
}

sub get_deps {
	my $self = shift;
	$self->load_deps; # just in case

	return %{$self->{deps}};
}

sub set_inc {
	my $self = shift;
	push @{ $self->{inc} }, @_;
}

sub set_libs {
	#my $self = shift;
	#push @{ $self->{libs} }, @_;
	my ($self, $newlibs) = @_;
	$self->{libs} = $newlibs;
}

sub add_pm {
	my ($self, %pm) = @_;
	while (my ($key, $value) = each %pm) {
		$self->{pm}{$key} = $value;
	}
}

sub _listkey_add_list {
	my ($self, $key, @list) = @_;
	$self->{$key} = [] unless $self->{$key};
	push @{ $self->{$key} }, @list;
}

sub add_xs       { shift->_listkey_add_list ('xs',       @_) }
sub add_c        { shift->_listkey_add_list ('c',        @_) }
sub add_typemaps {
	my $self = shift;
	$self->_listkey_add_list ('typemaps', @_);
	$self->install (@_);
}

sub add_headers { }

####### PRIVATE
sub basename { (File::Spec->splitdir ($_[0]))[-1] }
# get the name in Makefile syntax.
sub installed_filename {
	my $self = shift;
	return '$(INST_ARCHLIB)/$(FULLEXT)/Install/'.basename ($_[0]);
}

sub install {
	# install things by adding them to the hash of pm files that gets
	# passed through WriteMakefile's PM key.
	my $self = shift;
	foreach my $f (@_) {
		$self->add_pm ($f, $self->installed_filename ($f));
	}
}

sub save_config {
	use Data::Dumper;
	use IO::File;

	my ($self, $filename) = @_;
	warn "writing $filename\n";

	my $file = IO::File->new (">".$filename)
		or croak "can't open '$filename' for writing: $!\n";

	print $file "package $self->{name}\::Install::Files;\n\n";
	# for modern stuff
	print $file "".Data::Dumper->Dump([{
		inc => join (" ", @{ $self->{inc} }),
		libs => $self->{libs},
		typemaps => [ map { basename $_ } @{ $self->{typemaps} } ],
		deps => [keys %{ $self->{deps} }],
	}], ['self']);
	# for ancient stuff
	print $file "\n\n# this is for backwards compatiblity\n";
	print $file "\@deps = \@{ \$self->{deps} };\n";
	print $file "\@typemaps = \@{ \$self->{typemaps} };\n";
	print $file "\@headers = \@{ \$self->{headers} };\n";
	print $file "\$libs = \$self->{libs};\n";
	print $file "\$inc = \$self->{inc};\n";
	# this is riduculous, but old versions of ExtUtils::Depends take
	# first $loadedmodule::CORE and then $INC{$file} --- the fallback
	# includes the Filename.pm, which is not useful.  so we must add
	# this crappy code.  we don't worry about portable pathnames,
	# as the old code didn't either.
	(my $mdir = $self->{name}) =~ s{::}{/}g;
	print $file <<"EOT";

	\$CORE = undef;
	foreach (\@INC) {
		if ( -f \$_ . "/$mdir/Install/Files.pm") {
			\$CORE = \$_ . "/$mdir/Install/";
			last;
		}
	}
EOT

	print $file "\n1;\n";

	close $file;

#	system "cat $filename";

	# we need to ensure that the file we just created gets put into
	# the install dir with everything else.
	#$self->install ($filename);
	$self->add_pm ($filename, $self->installed_filename ('Files.pm'));
}

sub load {
	my $dep = shift;
	my @pieces = split /::/, $dep;
	my @suffix = qw/ Install Files /;
	my $relpath = File::Spec->catfile (@pieces, @suffix) . '.pm';
	my $depinstallfiles = join "::", @pieces, @suffix;
	eval {
		require $relpath 
	} or die " *** Can't load dependency information for $dep:\n   $@\n";
	#
	#print Dumper(\%INC);

	# effectively $instpath = dirname($INC{$relpath})
	@pieces = File::Spec->splitdir ($INC{$relpath});
	pop @pieces;
	my $instpath = File::Spec->catdir (@pieces);
	
	no strict;

	croak "no dependency information found for $dep"
		unless $instpath;

	warn "found $dep in $instpath\n";

	if (not File::Spec->file_name_is_absolute ($instpath)) {
		warn "instpath is not absolute; using cwd...\n";
		$instpath = File::Spec->rel2abs ($instpath);
	}

	my @typemaps = map {
		File::Spec->rel2abs ($_, $instpath)
	} @{"$depinstallfiles\::typemaps"};

	{
		instpath => $instpath,
		header   => \@{"$depinstallfiles\::header"},
		typemaps => \@typemaps,
		inc      => "-I$instpath ".${"$depinstallfiles\::inc"},
		libs     => ${"$depinstallfiles\::libs"},
		# this will not exist when loading files from old versions
		# of ExtUtils::Depends.
		(exists ${"$depinstallfiles\::"}{deps}
		  ? (deps => \@{"$depinstallfiles\::deps"})
		  : ()), 
	}
}

sub load_deps {
	my $self = shift;
	my @load = grep { not $self->{deps}{$_} } keys %{ $self->{deps} };
	foreach my $d (@load) {
		my $dep = load ($d);
		$self->{deps}{$d} = $dep;
		if ($dep->{deps}) {
			foreach my $childdep (@{ $dep->{deps} }) {
				warn("adding $childdep to load"),push @load, $childdep
					unless
						$self->{deps}{$childdep}
					or
						grep {$_ eq $childdep} @load;
			}
		}
	}
}

sub uniquify {
	my %seen;
	# we use a seen hash, but also keep indices to preserve
	# first-seen order.
	my $i = 0;
	foreach (@_) {
		$seen{$_} = ++$i
			unless exists $seen{$_};
	}
	#warn "stripped ".(@_ - (keys %seen))." redundant elements\n";
	sort { $seen{$a} <=> $seen{$b} } keys %seen;
}


sub get_makefile_vars {
	my $self = shift;

	# collect and uniquify things from the dependencies.
	# first, ensure they are completely loaded.
	$self->load_deps;
	
	##my @defbits = map { split } @{ $self->{defines} };
	my @incbits = map { split } @{ $self->{inc} };
	my @libsbits = split /\s+/, $self->{libs};
	my @typemaps = @{ $self->{typemaps} };
	foreach my $d (keys %{ $self->{deps} }) {
		my $dep = $self->{deps}{$d};
		#push @defbits, @{ $dep->{defines} };
		push @incbits, @{ $dep->{defines} } if $dep->{defines};
		push @incbits, split /\s+/, $dep->{inc} if $dep->{inc};
		push @libsbits, split /\s+/, $dep->{libs} if $dep->{libs};
		push @typemaps, @{ $dep->{typemaps} } if $dep->{typemaps};
	}

	# we have a fair bit of work to do for the xs files...
	my @clean = ();
	my @OBJECT = ();
	my %XS = ();
	foreach my $xs (@{ $self->{xs} }) {
		(my $c = $xs) =~ s/\.xs$/\.c/i;
		(my $o = $xs) =~ s/\.xs$/\$(OBJ_EXT)/i;
		$XS{$xs} = $c;
		push @OBJECT, $o;
		# according to the MakeMaker manpage, the C files listed in
		# XS will be added automatically to the list of cleanfiles.
		push @clean, $o;
	}

	# we may have C files, as well:
	foreach my $c (@{ $self->{c} }) {
		(my $o = $c) =~ s/\.c$/\$(OBJ_EXT)/i;
		push @OBJECT, $o;
		push @clean, $o;
	}

	my %vars = (
		INC => join (' ', uniquify @incbits),
		LIBS => join (' ', uniquify @libsbits),
		TYPEMAPS => [@typemaps],
		PM => $self->{pm},
	);
	$vars{clean} = { FILES => join (" ", @clean), }
		if @clean;
	$vars{OBJECT} = join (" ", @OBJECT)
		if @OBJECT;
	$vars{XS} = \%XS
		if %XS;

	%vars;
}

1;

__END__
#############
package main;

use Data::Dumper;
use ExtUtils::PkgConfig;
use ExtUtils::Depends;

my $real = 0;
if ($ARGV[-1] eq '-d') {
	pop @ARGV;
	$real++;
}

my %pkgconfig = ExtUtils::PkgConfig->find ('libgnomecanvas-2.0');
#my %pkgconfig = ExtUtils::PkgConfig->find ('libgnomeui-2.0');

my $dep;
if ($real) {
	$dep = new ExtUtils::Depends @ARGV;
} else {
	$dep = new NewDepends @ARGV;
}

#print Dumper( $dep );

my @xs_files = qw(
	Foo.xs Bar.xs Baz.xs Q.xs Qu.xs Quu.xs
);
my %pm_files = (
	'Baz.pm' => '$(INST_LIBDIR)/$(FULLEXT).pm',
	'Q.pm' => '$(INST_LIBDIR)/$(FULLEXT)/Q.pm',
	'Qu.pm' => '$(INST_LIBDIR)/$(FULLEXT)/Qu.pm',
	'Quu.pm' => '$(INST_LIBDIR)/$(FULLEXT)/Quu.pm',
);

$dep->set_inc ($pkgconfig{cflags});
$dep->set_libs ($pkgconfig{libs});
$dep->add_pm (%pm_files);
$dep->add_xs (@xs_files);
$dep->add_typemaps (qw(typemap foo.typemap build/bar.typemap));

$dep->save_config ('foo.pm');

#print Dumper( $dep );
print Dumper({$dep->get_makefile_vars})
