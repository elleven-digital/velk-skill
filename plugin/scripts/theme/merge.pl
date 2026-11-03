#!/usr/bin/perl
# merge.pl — three-way merge of two theme trees against their starting point.
#
#   merge.pl --base-dir B --base-manifest B.json --mine-dir M --mine-manifest M.json
#            --theirs-dir T --theirs-manifest T.json --out O
#
# base   = the version the local copy started from — an empty tree when there
#          is none: then a file on both sides that differs is a conflict
#          (nothing is joined silently), and a file on one side only is kept
#          or brought in;
# mine   = the local copy;
# theirs = what is live right now, published by the skill or changed by hand.
#
# Writes the result into O (empty) and prints
#   {"status":"clean"|"conflicts","took_theirs":[…],"merged":[…],
#    "deleted":[…],"conflicts":[{"path":…,"kind":…}]}
# "deleted" lists files the result drops that are still live: publishing
# them needs the user's confirmation. Exit 0 clean, 3 conflicts, 2 error.
#
# Rules, per file (spec 4.2):
#   mine == theirs                      keep
#   only mine changed / only theirs     mine / theirs                     (took_theirs)
#   both changed, text                  diff3 -m: clean → merged, else conflict "text"
#   both changed, binary (NUL byte)     conflict "binary", keeps mine
#   created here only / there only      keep / take theirs                (took_theirs)
#   created on both sides, different    conflict "added-both" (diff3 against empty)
#   they deleted, mine untouched        gone
#   I deleted, theirs untouched         gone                              (deleted)
#   I changed, they deleted             conflict "changed-here-deleted-there", keeps mine
#   I deleted, they changed             conflict "deleted-here-changed-there", keeps theirs
#   site.json clean by diff3 but not valid JSON → conflict "invalid-json"
use strict;
use warnings;
use Getopt::Long;
use JSON::PP;
use Encode qw(encode);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my %o;
GetOptions(\%o, map { "$_=s" } qw(base-dir base-manifest mine-dir mine-manifest
                                  theirs-dir theirs-manifest out))
    && keys %o == 7 or do { print STDERR "merge.pl: all seven options are required\n"; exit 2 };

my $JSON = JSON::PP->new->utf8->canonical;
my $tmp  = tempdir(CLEANUP => 1);
my $n    = 0;                                            # temp file counter
my (@took, @merged, @deleted, @conflicts);

eval { merge_all(); 1 } or do { print STDERR "merge.pl: $@"; exit 2 };

print $JSON->encode({
    status      => @conflicts ? 'conflicts' : 'clean',
    took_theirs => \@took,
    merged      => \@merged,
    deleted     => \@deleted,
    conflicts   => \@conflicts,
}), "\n";
exit(@conflicts ? 3 : 0);

sub merge_all {
    my ($B, $M, $T) = map { files_of($o{$_}) } qw(base-manifest mine-manifest theirs-manifest);
    my %all = map { $_ => 1 } (keys %$B, keys %$M, keys %$T);

    for my $p (sort keys %all) {
        my ($b, $m, $t) = ($B->{$p}, $M->{$p}, $T->{$p});
        my $conflict = sub { push @conflicts, { path => $p, kind => $_[0] } };

        if (defined $m && defined $t && $m eq $t) { take('mine-dir', $p); next }
        next if !defined $m && !defined $t;                  # gone on both sides

        if (defined $b) {
            my $mine_same   = defined $m && $m eq $b;
            my $theirs_same = defined $t && $t eq $b;
            if    ($mine_same && !defined $t)   { next }                                   # they deleted
            elsif ($mine_same)                  { take('theirs-dir', $p); push @took, $p }  # they changed
            elsif (!defined $m && $theirs_same) { push @deleted, $p }                      # I deleted
            elsif (!defined $m)                 { take('theirs-dir', $p); $conflict->('deleted-here-changed-there') }
            elsif ($theirs_same)                { take('mine-dir', $p) }                   # I changed
            elsif (!defined $t)                 { take('mine-dir', $p); $conflict->('changed-here-deleted-there') }
            else {                                                                         # both changed
                my @sides = map { src($_, $p) } qw(mine-dir base-dir theirs-dir);
                if (grep { binary($_) } @sides) { take('mine-dir', $p); $conflict->('binary'); next }
                my ($code, $out) = diff3(map { slurp($_) } @sides);
                put_out($p, $out, (stat $sides[0])[2]);
                if ($code == 1) { $conflict->('text'); next }
                if ($p eq 'site.json' && !eval { $JSON->decode($out); 1 }) { $conflict->('invalid-json'); next }
                push @merged, $p;
            }
            next;
        }

        # Not in the base: created since.
        if (defined $m && !defined $t) { take('mine-dir', $p); next }
        if (defined $t && !defined $m) { take('theirs-dir', $p); push @took, $p; next }
        my ($mf, $tf) = (src('mine-dir', $p), src('theirs-dir', $p));
        if (binary($mf) || binary($tf)) { take('mine-dir', $p); $conflict->('binary'); next }
        my ($mine, $theirs) = (slurp($mf), slurp($tf));
        my ($code, $out) = diff3($mine, '', $theirs);
        # With one side empty diff3 sees a single change and joins silently;
        # both sides did create the file, so it gets its markers all the same.
        $out = markers($mine, $theirs) if $code == 0;
        put_out($p, $out, (stat $mf)[2]);
        $conflict->('added-both');
    }
}

sub files_of {
    open my $fh, '<:raw', $_[0] or die "cannot read $_[0]\n";
    my $d = $JSON->decode(do { local $/; <$fh> });
    return $d->{files} || {};
}
sub fs    { encode('UTF-8', $_[0]) }                        # path → bytes on disk
sub src   { "$o{$_[0]}/" . fs($_[1]) }                      # src('mine-dir', $p)
sub slurp {                                                 # always one value: '' for an empty file
    open my $fh, '<:raw', $_[0] or die "cannot read $_[0]\n";
    local $/;
    my $bytes = <$fh>;
    return $bytes // '';
}
sub put_out {                                               # put_out($p, $bytes, $mode)
    my ($p, $bytes, $mode) = @_;
    my $dst = "$o{out}/" . fs($p);
    make_path(dirname($dst));
    open my $fh, '>:raw', $dst or die "cannot write $dst\n";
    print $fh $bytes;
    close $fh;
    chmod $mode & 07777, $dst;
}
sub take {                                                  # take('theirs-dir', $p)
    my ($side, $p) = @_;
    my $from = src($side, $p);
    put_out($p, slurp($from), (stat $from)[2]);
}
sub binary {
    open my $fh, '<:raw', $_[0] or return 0;
    read $fh, my $head, 8000;
    return index($head // '', "\0") >= 0;
}

# diff3 works line by line; a missing final newline would glue its markers to
# the last line. Every side gets one for the merge, and a clean result drops
# it again when neither side had it.
sub diff3 {                                                 # → (exit code, merged bytes)
    my ($mine, $base, $theirs) = @_;
    my @files = map { with_newline($_) } ($mine, $base, $theirs);
    open my $fh, '-|', 'diff3', '-m', '-L', 'local', '-L', 'base', '-L', 'server', @files
        or die "cannot run diff3\n";
    my $out = do { local $/; <$fh> } // '';
    close $fh;
    my $code = $? >> 8;
    die "diff3 failed\n" if $code > 1;
    my $bare = sub { length $_[0] && substr($_[0], -1) ne "\n" };
    $out =~ s/\n\z// if $code == 0 && $bare->($mine) && $bare->($theirs);
    return ($code, $out);
}
sub markers {                                               # diff3 -m's block around two whole sides
    my ($mine, $theirs) = map { length $_ && substr($_, -1) ne "\n" ? "$_\n" : $_ } @_;
    return "<<<<<<< local\n${mine}||||||| base\n=======\n${theirs}>>>>>>> server\n";
}
sub with_newline {
    my ($bytes) = @_;
    my $f = "$tmp/" . $n++;
    open my $fh, '>:raw', $f or die "cannot write $f\n";
    print $fh $bytes, (length $bytes && substr($bytes, -1) ne "\n" ? "\n" : '');
    close $fh;
    return $f;
}
