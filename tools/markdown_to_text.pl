#!/usr/bin/env perl
use strict;
use warnings;

# Small, dependency-free renderer for the limited Markdown used by the
# distribution manuals. It intentionally produces conservative plain text
# suitable for the Sprinter DSS viewer.

my $in_fence = 0;

while (my $line = <>) {
    $line =~ s/\r?\n\z//;

    if ($line =~ /^\s*```/) {
        $in_fence = !$in_fence;
        next;
    }

    if (!$in_fence) {
        next if $line =~ /^\s*\|?[\s:|-]*---[\s:|-]*\|?\s*$/;

        $line =~ s/^\s{0,3}#{1,6}\s+//;
        $line =~ s/^\s*>\s?//;

        if ($line =~ /^\s*\|.*\|\s*$/) {
            $line =~ s/^\s*\|//;
            $line =~ s/\|\s*$//;
            my @cells = split /\|/, $line, -1;
            for my $cell (@cells) {
                $cell =~ s/^\s+//;
                $cell =~ s/\s+$//;
            }
            $line = join('  |  ', @cells);
        }
    }

    $line =~ s/!\[([^]]*)\]\([^)]+\)/$1/g;
    $line =~ s/\[([^]]+)\]\(([^)]+)\)/$1 ($2)/g;
    $line =~ s/`//g;
    $line =~ s/\*\*//g;
    $line =~ s/\*([^*]+)\*/$1/g;
    $line =~ s/__//g;

    print $line, "\n";
}
