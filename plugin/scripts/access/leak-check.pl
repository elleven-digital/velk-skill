#!/usr/bin/perl
# leak-check.pl --file <access.velk> [--config <ssh.json>]
#
# Re-reads a written access file and proves two things:
#   1. every key in it is on the allowlist;
#   2. with --config, no value the config holds back appears anywhere in it —
#      not as a field of its own and not inside an allowed one.
#
# "Holds back" is deny-by-default: every config field is treated as secret
# except the ones public by nature (server address, paths, URLs, names), which
# legitimately show up inside site.url and path. A field added to ssh.json
# tomorrow is secret until someone decides otherwise.
#
# Prints KEY <path> / VALUE <config-path> per problem — the path, never the
# value. Exit 0 clean, 1 problems, 2 bad input.
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;

my %ALLOWED = map { $_ => 1 } qw(
    velk_access site.url site.subpath ssh.host ssh.port ssh.user path
    created_by created_at
    remote.php_bin rsync.theme_extra_excludes
);
my @PUBLIC = (
    qr/^ssh\./, qr/^site\./, qr/^rsync\./, qr/^remote\./, qr/^access\./,
    qr/^(identity|mode)$/, qr/^db\.(host|name|user)$/,
    qr/^local\.(db_host|db_name|db_user|php_bin)$/,
);
my $MIN_SECRET_LENGTH = 4;

my ($file, $config);
GetOptions('file=s' => \$file, 'config=s' => \$config) && $file
    or do { print STDERR "usage: leak-check.pl --file <f> [--config <c>]\n"; exit 2 };

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; <$fh> }
sub leaves {                      # leaves($data) → ([path, value], ...)
    my ($d, $prefix, $out) = @_;
    $out //= [];
    if (ref $d eq 'HASH') {
        leaves($d->{$_}, defined $prefix ? "$prefix.$_" : $_, $out) for sort keys %$d;
    } elsif (ref $d eq 'ARRAY') {
        leaves($d->[$_], "$prefix\[$_\]", $out) for 0 .. $#$d;
    } else {
        push @$out, [$prefix // '', defined $d ? "$d" : ''];
    }
    return $out;
}

my $raw = slurp($file);
defined $raw or do { print STDERR "cannot read $file\n"; exit 2 };
my $access = eval { JSON::PP->new->utf8->decode($raw) };
ref $access eq 'HASH' or do { print STDERR "$file is not a JSON object\n"; exit 2 };
my $leaves = leaves($access);

my @problems = map { "KEY $_->[0]" } grep { (my $k = $_->[0]) =~ s/\[\d+\]//g; !$ALLOWED{$k} } @$leaves;

if ($config) {
    my $cfg_raw = slurp($config);
    my $cfg = defined $cfg_raw ? eval { JSON::PP->new->utf8->decode($cfg_raw) } : undef;
    ref $cfg eq 'HASH' or do { print STDERR "cannot read config $config\n"; exit 2 };
    # The decoded leaves are searched too, so a JSON escape can't hide a value.
    my @haystack = ($raw, map { ($_->[0], $_->[1]) } @$leaves);
    for my $leaf (@{ leaves($cfg) }) {
        my ($path, $value) = @$leaf;
        next if grep { $path =~ $_ } @PUBLIC;
        next if length($value) < $MIN_SECRET_LENGTH;
        push @problems, "VALUE $path" if grep { index($_, $value) >= 0 } @haystack;
    }
}

print "$_\n" for @problems;
exit(@problems ? 1 : 0);
