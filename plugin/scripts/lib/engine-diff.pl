#!/usr/bin/perl
# engine-diff.pl <release-dir> <project-dir>
#
# Compares the project's engine with a published release, file by file. What
# counts as "the engine" is engine_paths in the RELEASE's engine-manifest.json
# (an install deletes its own copy). Paths in post_install_cleanup may be
# absent from the project — an install removes them — but when present they
# must match. .DS_Store is Finder noise and never counts, and .gitignore is
# the project's own: an install removes the engine's copy so the project can
# keep one (deploy.md and connect.sh have it ignore .deploy/).
#
# Prints one line per difference — CHANGED/ADDED/MISSING <path> — or
# ENGINE_OK. Exit 0 when identical, 1 when not, 2 on bad input.
use strict;
use warnings;
use JSON::PP;
use Digest::SHA;
use File::Find;

my ($release, $project) = @ARGV;
die "usage: engine-diff.pl <release-dir> <project-dir>\n" unless defined $project;
$release =~ s{/+$}{};
$project =~ s{/+$}{};

open my $fh, '<:raw', "$release/engine-manifest.json"
    or do { print STDERR "no engine-manifest.json in $release\n"; exit 2 };
my $manifest = JSON::PP->new->decode(do { local $/; <$fh> });
my @engine  = @{ $manifest->{engine_paths} || [] };
my %cleanup = map { $_ => 1 } @{ $manifest->{post_install_cleanup} || [] };
if (!@engine) { print STDERR "engine_paths is empty\n"; exit 2 }

sub sha { my $d = Digest::SHA->new(256); $d->addfile($_[0], 'b'); $d->hexdigest }

# files_under <root> <rel> — engine files below root/rel, as paths relative to root.
sub files_under {
    my ($root, $rel) = @_;
    my $base = "$root/$rel";
    return () unless -e $base;
    return ($rel) if -f $base;
    my @out;
    find({ no_chdir => 1, wanted => sub {
        return unless -f $_ && !-l $_;
        return if (split m{/}, $_)[-1] eq '.DS_Store';
        push @out, substr($_, length($root) + 1);
    } }, $base);
    return @out;
}

my @report;
for my $p (@engine) {
    next if $p =~ m{^/} || $p =~ m{\.\.};      # never look outside the install
    next if $p eq '.gitignore';
    (my $rel = $p) =~ s{/$}{};
    next if $cleanup{$p} && !-e "$project/$rel";
    my %want = map { $_ => 1 } files_under($release, $rel);
    my %have = map { $_ => 1 } files_under($project, $rel);
    for my $f (sort keys %want) {
        if (!$have{$f})                                  { push @report, "MISSING $f" }
        elsif (sha("$release/$f") ne sha("$project/$f")) { push @report, "CHANGED $f" }
    }
    push @report, map { "ADDED $_" } grep { !$want{$_} } sort keys %have;
}

if (@report) { print "$_\n" for @report; exit 1 }
print "ENGINE_OK\n";
exit 0;
