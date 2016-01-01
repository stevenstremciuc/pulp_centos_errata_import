#!/usr/bin/perl

# This script imports CentOS Errata into Katello
# It relies on preformatted information since parsing email
# is the road to madness...
#
# To run this script on CentOS 5.x you need 
# perl-XML-Simple, perl-Text-Unidecode and perl-Frontier-RPC
#
# This script was modified from Steve Meier's script which
# can be found at http://cefs.steve-meier.de/
#


# Test for required modules
&eval_modules;

# Load modules
use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
import Text::Unidecode;
import XML::Simple;

# Version information
my $version = "20150616";

# Variable declation
$| = 1;
my $user;
my $password;
my ($xml, $erratafile, $rhsaxml, $rhsaovalfile);
my (%name2id, %name2channel);
my $publish = 0; # do not publish by default
my $debug = 0;
my $quiet = 0;
my $getopt;
my $reference;
my $result;
my ($pkg, $allpkg, @pkgdetails, $package);
my @packages;
my @channels;
my ($type, $synopsis);
my ($advisory, $advid, $ovalid);
my %existing;
my @repolist;

# Print call and parameters if in debug mode (GetOptions will clear @ARGV)
if (join(' ',@ARGV) =~ /--debug/) { print STDERR "DEBUG: Called as $0 ".join(' ',@ARGV)."\n"; }

# Parse arguments
$getopt = GetOptions( 'errata=s'		=> \$erratafile,
                      'rhsa-oval=s'		=> \$rhsaovalfile,
                      'debug'			=> \$debug,
                      'quiet'			=> \$quiet,
                      'user=s'			=> \$user,
                      'password=s'		=> \$password,
                      'include-repo=s{,}'	=> \@repolist
                     );

# Check for arguments
if ( not(defined($erratafile))) {
  &usage;
  exit 1;
}

# Do we have a proper errata file?
if (not(-f $erratafile)) {
  &error("$erratafile is not an errata file!\n");
  exit 1;
}

# Output $version string in debug mode
&debug("Version is $version\n");

#############################
# Initialize connection #
#############################
&login;

############################
# Read the XML errata file #
############################
&info("Loading errata XML\n");
if (not($xml = XMLin($erratafile))) {
  &error("Could not parse errata file!\n");
  exit 4;
}
&debug("XML loaded successfully\n");

# Check that we can handle the data
if (defined($xml->{meta}->{minver})) {
  if ($xml->{meta}->{minver} > $version) {
    &error("This script is too old to handle this data file. Please update.\n");
    exit 5;
  }
}

##################################
# Load optional Red Hat OVAL XML #
##################################
if (defined($rhsaovalfile)) {
  if (-f $rhsaovalfile) {
    &info("Loading Red Hat OVAL XML\n");
    if (not($rhsaxml = XMLin($rhsaovalfile))) {
      &error("Could not parse Red Hat OVAL file!\n");
      exit 4;
    }

    &debug("Red Hat OVAL XML loaded successfully\n");
  }
}

########################
# Get server inventory #
########################
&info("Getting server inventory\n");

if(!@repolist) {
  &debug("Getting full repo list\n");
  @repolist = `pulp-admin repo list -s | awk '{print \$1}' `;
}
else {
  &debug("Using repo list from command line options: ".join(', ',@repolist)."\n");
}

# Go through each channel 
foreach my $repo (sort(@repolist)) {
  chomp $repo;
  &debug("Getting errata from $repo\n");

  # Collect existing errata
  my @repoerrata = `pulp-admin rpm repo content errata --repo-id=$repo --fields=id | grep Id: | awk '{print \$2}' `;
  chomp @repoerrata;
  foreach my $errata (@repoerrata) {
    &debug("Found existing errata for $errata\n");
    $existing{$errata} = 1;
  }

  # Get all packages in current channel
  my @allpkg = `pulp-admin rpm repo content rpm --repo-id=$repo --fields=filename | grep Filename: | awk '{print \$2}' `;
  chomp @allpkg;

  # Go through each package
  foreach $pkg (@allpkg) {
    # Get the details of the current package
    $name2id{$pkg} = $pkg;
    $name2channel{$pkg} = $repo;
  }
}

##############################
# Process errata in XML file #
##############################

# Go through each <errata>
foreach $advisory (sort(keys(%{$xml}))) {

  # Restore "proper" name of adivsory
  $advid = $advisory;
  $advid =~ s/--/:/;
  
  @packages = ();
  @channels = ();

  # Only consider CentOS (and Debian) errata
  unless($advisory =~ /^CE|^DSA/) { &debug("Skipping $advid\n"); next; }

  # Start processing
  &debug("Processing $advid\n");

  # Generate OVAL ID for security errata
  $ovalid = "";
  if ($advid =~ /CESA/) {
    if ($advid =~ /CESA-(\d+):(\d+)/) {
      $ovalid = "oval:com.redhat.rhsa:def:$1".sprintf("%04d", $2);
      &debug("Processing $advid -- OVAL ID is $ovalid\n");
    }
  }

  # Check if the errata already exists
  if (not(defined($existing{$advid}))) {
    # Errata does not exist yet
    
    # Find package IDs mentioned in errata
    &find_packages($advisory);

    # Insert description from Red Hat OVAL file, if available (only for Security)
    if (defined($ovalid)) {
      if ( defined($rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{description}) ) {
        &debug("Using description from $ovalid\n");
        $xml->{$advisory}->{description} = $rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{description};
        # Remove Umlauts -- API throws errors if they are included
        $xml->{$advisory}->{description} = unidecode($xml->{$advisory}->{description});
        # Escape quotes in the description
        $xml->{$advisory}->{description} =~ s/\"/\\\"/g;
      }
    }

    if (@packages >= 1) {
      # If there is at least one matching package create the errata?
      if ( ref($xml->{$advisory}->{packages}) eq 'ARRAY') {
        &info("Creating errata for $advid ($xml->{$advisory}->{synopsis}) (".($#packages +1)." of ".($#{$xml->{$advisory}->{packages}} +1).")\n");
      } else {
        &info("Creating errata for $advid ($xml->{$advisory}->{synopsis}) (1 of 1)\n");
      }

      ##### Create reference file ######
      my $reffile = "/tmp/$advid.ref.csv";
      open(my $fh, '>'.$reffile) or die "Could not open file '$reffile' $!";

      $synopsis = $xml->{$advisory}->{synopsis};
      $synopsis =~ s/,/;/g;

      foreach my $reference (split / +/, $xml->{$advisory}->{references}) {
        print $fh "$reference,$xml->{$advisory}->{type},$advid,$synopsis\n";
      }
      close $fh;
      ##################################

      #### Create package list file ####
      my $packfile = "/tmp/$advid.pack.csv";
      open( $fh, '>'.$packfile) or die "Could not open file '$packfile' $!";
      foreach my $package (@packages) {

        # Escape plus signs in file names.
        my $filename = $package;
        $filename =~ s/\+/\\\+/g;

        @pkgdetails = `pulp-admin rpm repo content rpm --repo-id=$name2channel{$package} --match="filename=$filename" --fields=name,version,release,epoch,arch,checksum,checksumtype | awk '{print \$2}'`;
        chomp @pkgdetails;
        print $fh "$pkgdetails[4],$pkgdetails[6],$pkgdetails[5],$pkgdetails[3],$pkgdetails[0],$package,$pkgdetails[1],$pkgdetails[2],N/A\n";
      }
      close $fh;
      #################################

      ####### Select correct type #####
		if($xml->{$advisory}->{type} eq "Security Advisory") {  $type = "security"; }
		elsif($xml->{$advisory}->{type} eq "Bug Fix Advisory")	{ $type = "bugfix"; }
		elsif($xml->{$advisory}->{type} eq "Product Enhancement Advisory") { $type = "enhancement"; }
		else { $type = $xml->{$advisory}->{type}; }
      #################################

      ####### Upload the errata #######
      $result = `pulp-admin rpm repo uploads erratum --title="$xml->{$advisory}->{synopsis}" --description="$xml->{$advisory}->{description}" --version=$xml->{$advisory}->{release} --release="$pkgdetails[5]" --type="$type" --status="final" --updated="$xml->{$advisory}->{issue_date}" --issued="$xml->{$advisory}->{issue_date}" --reference-csv=$reffile --pkglist-csv=$packfile --from=$xml->{$advisory}->{from} --repo-id=$name2channel{$packages[0]} --erratum-id=$advid`;

      &info("$result\n");
      #################################

    } else {
      # There is no related package so there is no errata created
      &notice("Skipping errata $advid ($xml->{$advisory}->{synopsis}) -- No packages found\n");
    }

  } else {
    &info("Errata for $advid already exists\n");
  }
}

&logout;
exit;

# SUBS
sub debug() {
  if ($debug) { print "DEBUG: @_"; }
}

sub info() {
  if ($quiet) { return; }
  print "INFO: @_";
}

sub warning() {
  print "WARNING: @_";
}

sub error() {
  print "ERROR: @_";
}

sub notice() {
  if ($quiet) { return; }
  print "NOTICE: @_";
}

sub usage() {
  print "Usage: $0 --errata=<ERRATA-FILE> --user=admin --password=pass\n";
  print "         [ --quiet | --debug ]\n";
  print "\n";
  print "REQUIRED:\n";
  print "  --errata\t\tThe XML file containing errata information\n";
  print "  --user\t\tPulp user\n";
  print "  --password\t\tPulp password\n";
  print "\n";
  print "OPTIONAL\n";
  print "  --rhsa-oval\tOVAL XML file from Red Hat (recommended)\n";
  print "  --include-repo\tOnly consider packages and errata in the provided repositories. Can be provided multiple times\n";
  print "\n";
  print "LOGGING:\n";
  print "  --quiet\t\tOnly print warnings and errors\n";
  print "  --debug\t\tSet verbosity to debug (use this when reporting issues!)\n";
  print "\n";
}

sub eval_modules() {
  eval { require Text::Unidecode; };
  if ($@) { die "ERROR: You are missing Text::Unidecode\n       CentOS: yum install perl-Text-Unidecode\n"; };

  eval { require XML::Simple; };
  if ($@) { die "ERROR: You are missing XML::Simple\n       CentOS: yum install perl-XML-Simple\n"; };
}

sub uniq() {
  my %all = ();
  @all{@_} = 1;
  return (keys %all);
}

sub login() {
  if (not(defined($user))) {
    &error("\$user not set\n");
    exit 3;
  }
  if (not(defined($password))) {
    &error("\$password not set\n");
    exit 3;
  }

  system("pulp-admin", "login", "--username", $user, "--password", $password);
  if ( $? != 0 )
  {
    &error("Login failed: $? - $! \n");
    exit 1;
  }
  else
  {
    &info("Login successful\n");
  }
}

sub logout() {
  &debug("Logging out.\n");
  system("pulp-admin", "logout");
}


sub find_packages() {
  #  INPUT: Advisory, e.g. CESA-2013:0123
  # OUTPUT: Array of Package IDs, Array of Channel Labels

  # Find package IDs mentioned in errata
  if ( ref($xml->{$_[0]}->{packages}) eq 'ARRAY') {
    foreach $package ( @{$xml->{$_[0]}->{packages}} ) {
      if (defined($name2id{$package})) {
        # We found it, nice
        &debug("Package: $package -> $name2id{$package} -> $name2channel{$package} \n");
        push(@packages, $name2id{$package});
        push(@channels, $name2channel{$package});
        # Ugly hack :)
        @packages = &uniq(@packages);
        @channels = &uniq(@channels);
       } else {
         # No such package, too bad
         &debug("Package: $package not found\n");
       }
     }
  } else {
    # errata has only one package
    if (defined($name2id{$xml->{$_[0]}->{packages}})) {
      # the one and only package is found
      &debug("Package: $xml->{$_[0]}->{packages} -> $name2id{$xml->{$_[0]}->{packages}} -> $name2channel{$xml->{$_[0]}->{packages}} \n");
      push(@packages, $name2id{$xml->{$_[0]}->{packages}});
      push(@channels, $name2channel{$xml->{$_[0]}->{packages}});
    } else {
      # no hit
      &debug("Package: $xml->{$_[0]}->{packages} not found\n");
    }
  }

}
