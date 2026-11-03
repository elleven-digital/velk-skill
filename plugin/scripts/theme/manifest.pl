#!/usr/bin/perl
# manifest.pl — theme manifests: {"files": {"<path>": "sha256:<hex>"}}.
#
#   manifest.pl hash <dir>     paths on stdin (from rsync --out-format=%n) → manifest
#   manifest.pl diff <a> <b>   {"added":[…],"changed":[…],"removed":[…]}, from a to b
#   manifest.pl same <a> <b>   exit 0 when both hold the same files with the same hashes
#   manifest.pl digest <m>     one sha256 over the whole file map
#   manifest.pl paths <m>      the paths, one per line, sorted
#
# Any JSON with a "files" object is a manifest — the server's .velk-theme.json,
# .deploy/theme-base.json or a bare {"files": …}; "-" reads it from stdin.
# Output is canonical (sorted keys, UTF-8), so equal maps are equal bytes.
use strict;
use warnings;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK LEAVE_SRC);

my $JSON = JSON::PP->new->utf8->canonical;

sub load {
    my ($path) = @_;
    my $fh;
    if ($path eq '-') { $fh = \*STDIN } else { open $fh, '<:raw', $path or die "cannot read $path\n" }
    my $data = $JSON->decode(do { local $/; <$fh> });
    ref $data eq 'HASH' && ref $data->{files} eq 'HASH' or die "$path has no files map\n";
    return $data->{files};
}

my $cmd = shift // '';

if ($cmd eq 'hash') {
    my $dir = shift // die "usage: manifest.pl hash <dir>\n";
    $dir =~ s{/+$}{};
    my %files;
    while (my $line = <STDIN>) {
        chomp $line;
        (my $rel = $line) =~ s/\\#([0-7]{3})/chr(oct($1))/ge;   # rsync's escape (openrsync and GNU alike)
        next if $rel eq '' || $rel =~ m{/$};
        my $full = "$dir/$rel";
        next unless -f $full && !-l $full;
        my $name = eval { decode('UTF-8', $rel, FB_CROAK | LEAVE_SRC) };
        defined $name or die "a theme file name is not valid UTF-8: $rel\n";
        my $sha = Digest::SHA->new(256);
        $sha->addfile($full, 'b');
        $files{$name} = 'sha256:' . $sha->hexdigest;
    }
    print $JSON->encode({ files => \%files }), "\n";
}
elsif ($cmd eq 'diff') {
    my ($a, $b) = (load($ARGV[0]), load($ARGV[1]));
    my %out = (added => [], changed => [], removed => []);
    for my $p (sort keys %$b) {
        if (!exists $a->{$p})        { push @{ $out{added} }, $p }
        elsif ($a->{$p} ne $b->{$p}) { push @{ $out{changed} }, $p }
    }
    push @{ $out{removed} }, grep { !exists $b->{$_} } sort keys %$a;
    print $JSON->encode(\%out), "\n";
}
elsif ($cmd eq 'same') {
    exit($JSON->encode(load($ARGV[0])) eq $JSON->encode(load($ARGV[1])) ? 0 : 1);
}
elsif ($cmd eq 'digest') {
    print sha256_hex($JSON->encode(load($ARGV[0]))), "\n";
}
elsif ($cmd eq 'paths') {
    my $files = load($ARGV[0]);
    binmode STDOUT, ':encoding(UTF-8)';
    print "$_\n" for sort keys %$files;
}
else {
    die "usage: manifest.pl hash|diff|same|digest|paths …\n";
}
