################################################################################
# WeBWorK mod_perl (c) 2000-2002 WeBWorK Project
# $Id$
################################################################################

package WeBWorK::PG::ImageGenerator;

=head1 NAME

WeBWorK::PG::ImageGenerator - create an object for holding bits of math for
LaTeX, and then to process them all at once.

=head1 SYNPOSIS

FIXME: add this

=cut

use strict;
use warnings;
use WeBWorK::EquationCache;

#use WeBWorK::Utils qw(readDirectory makeTempDirectory removeTempDirectory);
# can't use WeBWorK::Utils from here :(
# so we define the needed functions here instead
sub readDirectory($) {
	my $dirName = shift;
	opendir my $dh, $dirName
		or die "Failed to read directory $dirName: $!";
	my @result = readdir $dh;
	close $dh;
	return @result;
}
use constant MKDIR_ATTEMPTS => 10;
sub makeTempDirectory($$) {
	my ($parent, $basename) = @_;
	# Loop until we're able to create a directory, or it fails for some
	# reason other than there already being something there.
	my $triesRemaining = MKDIR_ATTEMPTS;
	my ($fullPath, $success);
	do {
		my $suffix = join "", map { ('A'..'Z','a'..'z','0'..'9')[int rand 62] } 1 .. 8;
		$fullPath = "$parent/$basename.$suffix";
		$success = mkdir $fullPath;
	} until ($success or not $!{EEXIST});
	unless ($success) {
		my $msg = '';
		$msg    .=  "Server does not have write access to the directory $parent" unless -w $parent;
		die "$msg\r\nFailed to create directory $fullPath:\r\n $!"
	}

	return $fullPath;
}

use File::Path qw(rmtree);
#FIXME: what is this for?
sub removeTempDirectory($) {
	my ($dir) = @_;
	rmtree($dir, 0, 0);
}

################################################################################

=head1 CONFIGURATION VARIABLES

=over

=item $DvipngArgs

Arguments to pass to dvipng.

=cut

our $DvipngArgs = "" unless defined $DvipngArgs;

=item $PreserveTempFiles

If true, don't delete temporary files.

=cut

our $PreserveTempFiles = 0 unless defined $PreserveTempFiles;

=item $TexPreamble

TeX to prepend to equations to be processed.

=cut

our $TexPreamble = "" unless defined $TexPreamble;

=item $TexPostamble

TeX to append to equations to be processed.

=cut

our $TexPostamble = "" unless defined $TexPostamble;

=back

=cut

################################################################################

=head1 METHODS

=over

=item new

Returns a new ImageGenerator object. C<%options> must contain the following
entries:

 tempDir  => directory in which to create temporary processing directory
 latex    => path to latex binary
 dvipng   => path to dvipng binary
 useCache => boolean, whether to use global image cache

If C<useCache> is false, C<%options> must also contain the following entries:

 dir	  => directory for resulting files
 url	  => url to directory for resulting files
 basename => base name for image files (i.e. "eqn-$psvn-$probNum")

If C<useCache> is true, C<%options> must also contain the following entries:

 cacheDir => directory for resulting files
 cacheURL => url to cacheDir
 cacheDB  => path to cache database file

=cut

sub new {
	my ($invocant, %options) = @_;
	my $class = ref $invocant || $invocant;
	my $self = {
		names   => [],
		strings => [],
		%options,
	};
	
	if ($self->{useCache}) {
		$self->{dir} = $self->{cacheDir};
		$self->{url} = $self->{cacheURL};
		$self->{basename} = "";
		$self->{equationCache} = WeBWorK::EquationCache->new(cacheDB => $self->{cacheDB});
	}
	
	bless $self, $class;
}

=item add($string, $mode)

Adds the equation in C<$string> to the object. C<$mode> can be "display" or
"inline". If not specified, "inline" is assumed. Returns the proper HTML tag
for displaying the image.

=cut

sub add {
	my ($self, $string, $mode) = @_;
	
	my $names    = $self->{names};
	my $strings  = $self->{strings};
	my $dir      = $self->{dir};
	my $url      = $self->{url};
	my $basename = $self->{basename};
	my $useCache = $self->{useCache};
	
	# if the string came in with delimiters, chop them off and set the mode
	# based on whether they were \[ .. \] or \( ... \). this means that if
	# the string has delimiters, the mode *argument* is ignored.
	if ($string =~ s/^\\\[(.*)\\\]$/$1/s) {
		$mode = "display";
	} elsif ($string =~ s/^\\\((.*)\\\)$/$1/s) {
		$mode = "inline";
	}
	# otherwise, leave the string and the mode alone.
	
	# assume that a bare string with no mode specified is inline
	$mode ||= "inline";
	
	# now that we know what mode we're dealing with, we can generate a "real"
	# string to pass to latex
	my $realString = ($mode eq "display")
		? '\(\displaystyle{' . $string . '}\)'
		: '\(' . $string . '\)';
	
	# determine what the image's "number" is
	my $imageNum;
	if($useCache) {
		$imageNum = $self->{equationCache}->lookup($realString);
		# insert a slash after 2 characters
		# this effectively divides the images into 16^2 = 256 subdirectories
		substr($imageNum,2,0) = '/';
	} else {
		$imageNum = @$strings + 1;
	}
	
	# We are banking on the fact that if useCache is true, then basename is empty.
	# Maybe we should simplify and drop support for useCache =0 and having a basename.

	# get the full file name of the image
	my $imageName = ($basename)
		? "$basename.$imageNum.png"
		: "$imageNum.png";
	
	# store the full file name of the image, and the "real" tex string to the object
	push @$names, $imageName;
	push @$strings, $realString;
	#warn "ImageGenerator: added string $realString with name $imageName\n";
	
	# ... and the full URL.
	my $imageURL = "$url/$imageName";
	
	my $imageTag  = ($mode eq "display")
		? " <div align=\"center\"><img src=\"$imageURL\" align=\"baseline\" alt=\"$string\"></div> "
		: " <img src=\"$imageURL\" align=\"baseline\" alt=\"$string\"> ";
	
	return $imageTag;
}

=item render(%options)

Uses LaTeX and dvipng to render the equations stored in the object. The 

=for comment

If the key "mtime" in C<%options> is given, its value will be interpreted as a
unix date and compared with the modification date on any existing copy of the
first image to be generated. It is recommended that the modification time of the
source file from which the equations originate be used for this value. If the
key "refresh" in C<%options> is true, images will be regenerated regardless of
when they were last modified. If neither option is supplied, "refresh" is
assumed.

=cut

sub render {
	my ($self, %options) = @_;
	
	my $tempDir  = $self->{tempDir};
	my $dir      = $self->{dir};
	my $basename = $self->{basename};
	my $latex    = $self->{latex};
	my $dvipng   = $self->{dvipng};
	my $names    = $self->{names};
	my $strings  = $self->{strings};
	
	# determine which images need to be generated
	my (@newStrings, @newNames);
	for (my $i = 0; $i < @$strings; $i++) {
		my $string = $strings->[$i];
		my $name = $names->[$i];
		if (-e "$dir/$name") {
			#warn "ImageGenerator: found a file named $name, skipping string $string\n";
		} else {
			#warn "ImageGenerator: didn't find a file named $name, including string $string\n";
			push @newStrings, $string;
			push @newNames, $name;
		}
	}
	
	return unless @newStrings; # Don't run latex if there are no images to generate
	
	# create temporary directory in which to do TeX processing
	my $wd = makeTempDirectory($tempDir, "ImageGenerator");
	
	# store equations in a tex file
	my $texFile = "$wd/equation.tex";
	open my $tex, ">", $texFile
		or die "failed to open file $texFile for writing: $!";
	print $tex $TexPreamble;
	print $tex "$_\n" foreach @newStrings;
	print $tex $TexPostamble;
	close $tex;
	warn "tex file $texFile was not written" unless -e $texFile;
	
	# call LaTeX
	my $latexCommand  = "cd $wd && $latex equation > latex.out 2> latex.err";
	my $latexStatus = system $latexCommand;

	if ($latexStatus and $latexStatus !=256) {
		warn "$latexCommand returned non-zero status $latexStatus: $!";
		warn "cd $wd failed" if system "cd $wd";
		warn "Unable to write to directory $wd. " unless -w $wd;
		warn "Unable to execute $latex " unless -e $latex ;
		
		warn `ls -l $wd`;
		my $errorMessage = '';
		if (-r "$wd/equation.log") {
			local(*LOGFILE);
			open LOGFILE,  "<$wd/equation.log" or die "Unable to read $wd/equation.log";
			local($/) = undef;
			$errorMessage = <LOGFILE>;
			close(LOGFILE);
			warn "<pre> Logfile contents:\n$errorMessage\n</pre>";
		} else {
		   warn "Unable to read logfile $wd/equation.log ";
		}
	}

	warn "$latexCommand failed to generate a DVI file"
		unless -e "$wd/equation.dvi";
	
	# call dvipng
	my $dvipngCommand = "cd $wd && $dvipng " . $DvipngArgs . " equation > dvipng.out 2> dvipng.err";
	my $dvipngStatus = system $dvipngCommand;
	warn "$dvipngCommand returned non-zero status $dvipngStatus: $!"
		if $dvipngStatus;
	
	# move/rename images
	foreach my $image (readDirectory($wd)) {
		# only work on equation#.png files
		next unless $image =~ m/^equation(\d+)\.png$/;
		
		# get image number from above match
		my $imageNum = $1;
		
		#warn "ImageGenerator: found generated image $imageNum with name $newNames[$imageNum-1]\n";
		
		# move/rename image
		#my $mvCommand = "cd $wd && /bin/mv $wd/$image $dir/$basename.$imageNum.png";
		# check to see if this requires a directory we haven't made yet
		my $newdir = $newNames[$imageNum-1];
		$newdir =~ s|/.*$||;
		if($newdir and not -d "$dir/$newdir") {
			my $success = mkdir "$dir/$newdir";
			warn "Could not make directory $dir/$newdir" unless $success;
		}
		my $mvCommand = "cd $wd && /bin/mv $wd/$image $dir/" . $newNames[$imageNum-1];
		my $mvStatus = system $mvCommand;
		if ( $mvStatus) {
			warn "$mvCommand returned non-zero status $mvStatus: $!";
			warn "Can't write to tmp/equations directory $dir" unless -w $dir;
		}

	}
	
	# remove temporary directory (and its contents)
	if ($PreserveTempFiles) {
		warn "ImageGenerator: preserved temp files in working directory '$wd'.\n";
	} else {
		removeTempDirectory($wd);
	}
}

=back

=cut

1;
