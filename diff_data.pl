#!/usr/bin/env perl

use utf8;
use warnings;
use 5.012;
use feature "unicode_strings";

use File::Slurp;
use JSON::MaybeXS;

binmode STDOUT, ":encoding(UTF-8)";

my $data_a_json = read_file($ARGV[0]);
my $data_b_json = read_file($ARGV[1]);

my $data_a = decode_json($data_a_json);
my $data_b = decode_json($data_b_json);

say "Old number of markers: ", scalar keys %$data_a;
say "New number of markers: ", scalar keys %$data_b;

my $num_removed_items = 0;
say "\nRemoved items:";
foreach my $qid (sort keys %$data_a) {
    next if exists $data_b->{$qid};
    $num_removed_items++;
    say "$num_removed_items. [$qid] $data_a->{$qid}{name}";
}

my $num_added_items = 0;
say "\nAdded items:";
foreach my $qid (sort keys %$data_b) {
    next if exists $data_a->{$qid};
    $num_added_items++;
    say "$num_added_items. [$qid] $data_b->{$qid}{name}";
}

my $num_modified_items = 0;
say "\nModified items:";
foreach my $qid (sort keys %$data_a) {

    next if not exists $data_b->{$qid};

    my $json_a = JSON->new->utf8->pretty->canonical->encode($data_a->{$qid});
    my $json_b = JSON->new->utf8->pretty->canonical->encode($data_b->{$qid});
    write_file("tmp-data-a.json", $json_a);
    write_file("tmp-data-b.json", $json_b);
    my $diff = `diff tmp-data-a.json tmp-data-b.json`;
    next unless $diff;

    $num_modified_items++;
    say "$num_modified_items. [$qid]\n$diff";
}

unlink("tmp-data-a.json", "tmp-data-b.json");
