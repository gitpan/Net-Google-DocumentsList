#line 1
package File::BOM;

#line 76

use strict;
use warnings;

# We don't want any character semantics at all
use bytes;

use base qw( Exporter );

use Readonly;

use Carp	qw( croak );
use Fcntl	qw( :seek );
use Encode	qw( :DEFAULT :fallbacks is_utf8 );
use Symbol	qw( gensym qualify_to_ref );

my @subs = qw(
	open_bom
	defuse
	decode_from_bom
	get_encoding_from_bom
	get_encoding_from_filehandle
	get_encoding_from_stream
    );

my @vars = qw( %bom2enc %enc2bom );

our $VERSION = '0.14';

our @EXPORT = ();
our @EXPORT_OK = ( @subs, @vars );
our %EXPORT_TAGS = (
	all  => \@EXPORT_OK,
	subs => \@subs,
	vars => \@vars
    );

#line 158

#line 179

our(%bom2enc, %enc2bom, $MAX_BOM_LENGTH, $bom_re);

# length in bytes of the longest BOM
$MAX_BOM_LENGTH = 4;

Readonly %bom2enc => (
	map { encode($_, "\x{feff}") => $_ } qw(
	    UTF-8
	    UTF-16BE
	    UTF-16LE
	    UTF-32BE
	    UTF-32LE
	)
    );

Readonly %enc2bom => (
	reverse(%bom2enc),
	map { $_ => encode($_, "\x{feff}") } qw(
	    UCS-2
	    iso-10646-1
	    utf8
	)
    );

{
    local $" = '|';

    my @bombs = sort { length $b <=> length $a } keys %bom2enc;

    Readonly $MAX_BOM_LENGTH => length $bombs[0];

    Readonly $bom_re => qr/^(@bombs)/o;
}

#line 266

sub open_bom (*$;$) {
    my($fh, $filename, $mode) = @_;
    if (defined $fh) {
	$fh = qualify_to_ref($fh, caller);
    }
    else {
	$fh = $_[0] = gensym();
    }

    my $enc;
    my $spill = '';

    open($fh, '<', $filename)
	or croak "Couldn't read '$filename': $!";

    if (wantarray) {
	($enc, $spill) = get_encoding_from_filehandle($fh);
    }
    else {
	$enc = get_encoding_from_filehandle($fh);
    }

    if ($enc) {
	$mode = ":encoding($enc)";

	$spill = decode($enc, $spill, FB_CROAK) if $spill;
    }

    if ($mode) {
	binmode($fh, $mode)
	    or croak "Couldn't set binmode of handle opened on '$filename' "
		   . "to '$mode': $!";
    }

    return wantarray ? ($enc, $spill) : $enc;
}

#line 320

sub defuse (*) {
    my $fh = qualify_to_ref(shift, caller);

    my($enc, $spill) = get_encoding_from_filehandle($fh);

    if ($enc) {
	binmode($fh, ":encoding($enc)");
	$spill = decode($enc, $spill, FB_CROAK) if $spill;
    }

    return wantarray ? ($enc, $spill) : $enc;
}

#line 353

sub decode_from_bom ($;$$) {
    my($string, $default, $check) = @_;

    croak "No string" unless defined $string;

    my($enc, $off) = get_encoding_from_bom($string);
    $enc ||= $default;

    my $out;
    if (defined $enc) {
	$out = decode($enc, substr($string, $off), $check);
    }
    else {
	$out = $string;
	$enc = '';
    }

    return wantarray ? ($out, $enc) : $out;
}

#line 394

sub get_encoding_from_filehandle (*) {
    my $fh = qualify_to_ref(shift, caller);

    my $enc;
    my $spill = '';
    if (seek($fh, 0, SEEK_SET)) {
	$enc = _get_encoding_seekable($fh);
    }
    elsif (wantarray) {
	($enc, $spill) = _get_encoding_unseekable($fh);
    }
    else {
	croak "Unseekable handle: $!";
    }

    return wantarray ? ($enc, $spill) : $enc;
}

#line 431

sub get_encoding_from_stream (*) {
    my $fh = qualify_to_ref(shift, caller);

    _get_encoding_unseekable($fh);
}

# internal: 
#
# Return encoding and seek to position after BOM
sub _get_encoding_seekable (*) {
    my $fh = shift;

    # This doesn't work on all platforms:
    # defined(read($fh, my $bom, $MAX_BOM_LENGTH))
        # or croak "Couldn't read from handle: $!";

    my $bom = eval { _safe_read($fh, $MAX_BOM_LENGTH) };
    croak "Couldn't read from handle: $@" if $@;

    my($enc, $off) = get_encoding_from_bom($bom);

    seek($fh, $off, SEEK_SET) or croak "Couldn't reset read position: $!";

    return $enc;
}

# internal:
#
# Return encoding and non-BOM overspill
sub _get_encoding_unseekable (*) {
    my $fh = shift;

    my $so_far = '';
    for my $c (1 .. $MAX_BOM_LENGTH) {
        # defined(read($fh, my $byte, 1)) or croak "Couldn't read byte: $!";
        my $byte = eval { _safe_read($fh, 1) };
        croak "Couldn't read byte: $@" if $@;

	$so_far .= $byte;

	# find matching BOMs
	my @possible = grep { $so_far eq substr($_, 0, $c) } keys %bom2enc;

	if (@possible == 1 and my $enc = $bom2enc{$so_far}) {
	    # There's only one match, this must be it
	    return ($enc, '');
	}
	elsif (@possible == 0) {
	    # might need to backtrack one byte
	    my $spill = chop $so_far;

	    if (my $enc = $bom2enc{$so_far}) {
		my $char_length = _get_char_length($enc, $spill);

                my $extra = eval {
                    _safe_read($fh, $char_length - length $spill);
                };
                croak "Coudln't read byte: $@" if $@;
		$spill .= $extra;

		return ($enc, $spill);
	    }
	    else {
		# no BOM
		return ('', $so_far . $spill);
	    }
	}
    }
}

sub _safe_read {
    my ($fh, $count) = @_;

    # read is supposed to return undef on error, but on some platforms it
    # seems to just return 0 and set $!
    local $!;
    my $status = read($fh, my $out, $count);

    die $! if !$status && $!;

    return $out;
}

#line 534

sub get_encoding_from_bom ($) {
    my $bom = shift;

    my $encoding = '';
    my $offset = 0;

    if (my($found) = $bom =~ $bom_re) {
	$encoding = $bom2enc{$found};
	$offset = length($found);
    }

    return ($encoding, $offset);
}

# Internal:
# Work out character length for given encoding and spillage byte
sub _get_char_length ($$) {
    my($enc, $byte) = @_;

    if ($enc eq 'UTF-8') {
	if (($byte & 0x80) == 0) {
	    return 1;
	}
	else {
	    my $length = 0;

	    1 while (($byte << $length++) & 0xc0) == 0xc0;

	    return $length;
	}
    }
    elsif ($enc =~ /^UTF-(16|32)/) {
	return $1 / 8;
    }
    else {
	return;
    }
}

#line 636

sub PUSHED { bless({offset => 0}, $_[0]) || -1 }

sub UTF8 {
  # There is a bug with this method previous to 5.8.7

    if ($] >= 5.008007) {
	return 1;
    }
    else {
	return 0;
    }
}

sub FILL {
    my($self, $fh) = @_;

    my $line;
    if (not defined $self->{enc}) {
	($self->{enc}, my $spill) = get_encoding_from_filehandle($fh);

	if ($self->{enc} ne '') {
	    binmode($fh, ":encoding($self->{enc})");
	    $line .= decode($self->{enc}, $spill, FB_CROAK) if $spill;

	    $self->{offset} = length $enc2bom{$self->{enc}};
	}

	$line .= <$fh>;
    }
    else {
	$line = <$fh>;
    }

    return $line;
}

sub WRITE {
    my($self, $buf, $fh) = @_;

    if (tell $fh == 0 and not $self->{wrote_bom}) {
	print $fh "\x{feff}";
	$self->{wrote_bom} = 1;
    }

    $buf = decode('UTF-8', $buf, FB_CROAK);

    print $fh $buf;

    return 1;
}

sub FLUSH { 0 }

sub SEEK {
    my $self = shift;

    my($pos, $whence, $fh) = @_;

    if ($whence == SEEK_SET) {
	$pos += $self->{offset};
    }

    if (seek($fh, $pos, $whence)) {
	return 0;
    }
    else {
	return -1;
    }
}

sub TELL {
    my($self, $fh) = @_;

    my $pos = tell $fh;

    if ($pos == -1) {
	return -1;
    }
    else {
	return $pos - $self->{offset};
    }
}

1;

__END__

#line 805

