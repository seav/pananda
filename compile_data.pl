#!/usr/bin/env perl

use utf8;
use warnings;
use 5.012;
use feature "unicode_strings";

use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use Encode;
use File::Slurp;
use JSON;
use List::Util qw(sum);
use LWP::UserAgent ();
use Parallel::ForkManager 0.007006;
use Term::ProgressBar;
use Text::CSV;
use URI::Escape;

use constant {
    LANGUAGE_CODE             => {
        Q1860  => "en",
        Q34057 => "tl",
        Q33239 => "ceb",
        Q35936 => "ilo",
        Q36121 => "pam",
        Q1321  => "es",
        Q188   => "de",
        Q150   => "fr",
    },
    ORDERED_LANGUAGES         => ['en', 'tl', 'ceb', 'ilo', 'pam', 'es', 'de', 'fr'],
    COUNTRY_QID               => "Q6256",
    REGION_QID                => "Q24698",
    PROVINCE_QID              => "Q24746",
    HUC_QID                   => "Q29946056",
    CITY_QID                  => "Q104157",
    MUNICIPALITY_QID          => "Q24764",
    METRO_MANILA_QID          => "Q13580",
    MANILA_QID                => "Q1461",
    DISTRICT_OF_MANILA_QID    => "Q15634883",
    WDQS_URL                  => "https://query.wikidata.org/sparql",
    COMMONS_API_URL           => "https://commons.wikimedia.org/w/api.php",
    WIKIDATA_API_URL          => "https://www.wikidata.org/w/api.php",
    WIKIDATA_MAX_STR_LENGTH   => 1500,
    SKIPPED_ADDRESS_LABELS    => {
        Q2863958 => 1,  # arrondissement of Paris
        Q90870   => 1,  # Arrondissement of Brussels-Capital
        Q240     => 1,  # Brussels-Capital Region
        Q8165    => 1,  # Karlsruhe Government Region
        Q2013767 => 1,  # Mitte (locality in Mitte)
        Q132480  => 1,  # Kantō region
        Q3551781 => 1,  # District of Columbia
    },
    SKIP_ADDRESS_HAVING => {
        Q16665915 => 1,  # Metropolis of Greater Paris
    },
    ADDRESS_LABEL_REPLACEMENT => {
        Q245546 => "6th arrondissement",
    },
    OVERSEAS_MACRO_ADDRESS    => {
        Q30130266 => "Tokyo, Japan",
        Q79945262 => "Tokyo, Japan",
        Q52878121 => "Dezhou, Shandong, China",
        Q30130018 => "Sydney, New South Wales, Australia",
        Q30131050 => "Paris, France",
        Q30127147 => "Ghent, Belgium",
        Q28874593 => "Brussels, Belgium",
        Q26709080 => "Wilhelmsfeld, Germany",
        Q23854678 => "Berlin, Germany",
        Q56810749 => "Vienna, Austria",
        Q63349729 => "Washington, D.C., United States",
        Q30133244 => "Chicago, Illinois, United States",
        Q30129474 => "Carson, California, United States",
        Q60232924 => "Jersey City, New Jersey, United States",
        Q60458584 => "Waipahu, Hawaii, United States",
        Q52984027 => "Guam, United States",
    },
};
use constant VALID_LANGUAGES => { map {($_, 1)} @{(ORDERED_LANGUAGES)} };

binmode STDIN , ":encoding(UTF-8)";
binmode STDOUT, ":encoding(UTF-8)";
binmode STDERR, ":encoding(UTF-8)";

my $Log_Level = 1;

my %Data;
my @error_msgs;

my @steps = (
    {
        title                => 'initial marker data with coordinates',
        is_wdqs_step         => 1,
        sparql_query         => get_initial_data_spaql_query(),

        csv_record_processor => \&process_initial_data_csv_record,

        # Check that the number of coordinates matches the number of plaques
        # and if the number of coordinates is more than 1, average them
        post_processor       => \&post_process_initial_data,

        set_helper_vars      => 1,
    },
    {
        title                => 'address data',
        is_wdqs_step         => 1,
        sparql_query         => get_address_data_sparql_query(),

        csv_record_processor => \&process_address_data_csv_record,
    },
    {
        title                => 'title data',
        is_wdqs_step         => 1,
        sparql_query         => get_title_data_sparql_query(),

        csv_record_processor => \&process_title_data_csv_record,

        # Sanity-check number of languages and titles, and also generate name field
        post_processor       => \&post_process_title_data,
    },
    {
        title                => 'short inscription data',
        is_wdqs_step         => 1,
        sparql_query         => get_inscription_data_sparql_query(),

        csv_record_processor => \&process_inscription_data_csv_record,
    },
    {
        title                => 'long inscription data',
        is_wdqs_step         => undef,

        process_datum        => \&query_long_inscription,
        callback             => \&process_long_inscription,
    },
    {
        title                => 'unveiling date data',
        is_wdqs_step         => 1,
        sparql_query         => get_unveiling_data_sparql_query(),

        csv_record_processor => \&process_unveiling_data_csv_record,
    },
    {
        title                => 'photo data',
        is_wdqs_step         => 1,
        sparql_query         => get_photo_data_sparql_query(),

        csv_record_processor => \&process_photo_data_csv_record,
    },
    {
        title                => 'photo metadata',
        is_wdqs_step         => undef,

        process_datum        => \&query_photo_metadata,
        callback             => \&process_photo_metadata,
    },
    {
        title                => 'commemorates-Wikipedia data',
        is_wdqs_step         => 1,
        sparql_query         => get_commemorates_data_sparql_query(),

        csv_record_processor => \&process_commemorates_data_csv_record,
    },
    {
        title                => 'Commons category data',
        is_wdqs_step         => 1,
        sparql_query         => get_category_data_sparql_query(),

        csv_record_processor => \&process_category_data_csv_record,
    },
);

my $num_markers;
my $sparql_values;

my $ua = LWP::UserAgent->new;
$ua->default_header(Accept => "text/csv");

foreach my $step (@steps) {

    say "INFO: Fetching and processing $step->{title}...";

    if ($step->{is_wdqs_step}) {
        my $sparql_query = $step->{sparql_query} =~ s/<<sparql_values>>/$sparql_values/r;
        my $response = $ua->post(WDQS_URL, {query => $sparql_query});
        foreach (parse_csv($response->decoded_content)) {
            $step->{csv_record_processor}->(@$_);
        }
        $step->{post_processor}->() if exists $step->{post_processor};
    }
    else {
        my $progress;
        $progress = Term::ProgressBar->new({count => $num_markers}) if $Log_Level == 1;
        my $pm = Parallel::ForkManager->new(32);
        $pm->run_on_finish($step->{callback});
        my $num_markers_processed = 0;
        while (my ($qid, $marker_data) = each %Data) {
            $progress->update(++$num_markers_processed) if $Log_Level == 1;
            $step->{process_datum}->($pm, $qid, $marker_data);
        }
        $pm->wait_all_children;
    }

    if (@error_msgs) {
        die join("\n", @error_msgs) . "\n";
    }

    if (exists $step->{set_helper_vars}) {
        $num_markers = scalar keys %Data;
        $sparql_values = "VALUES ?marker { " . join(" ", map { "wd:" . $_ } keys %Data) . " }";
    }
}


say "INFO: Marshalling data structure into final format...";
while (my ($qid, $marker_data) = each %Data) {
    if (
        $marker_data->{num_plaques} > 1 or
        scalar keys %{$marker_data->{details}} == 1
    ) {
        if (ref($marker_data->{photo}) eq "ARRAY") {
            shift @{$marker_data->{photo}};
        }
        foreach my $lang_code (keys %{$marker_data->{details}}) {
            my $hash_ref = $marker_data->{details}{$lang_code};
            $hash_ref->{text} = {};
            foreach my $key (qw/title subtitle inscription/) {
                $hash_ref->{text}{$key} = $hash_ref->{$key} if exists $hash_ref->{$key};
                delete $hash_ref->{$key};
            }
            if (
                $marker_data->{num_plaques} == 1 or
                ref($marker_data->{photo}) eq "ARRAY"
            ) {
                $hash_ref->{photo} = $marker_data->{photo} if exists $marker_data->{photo};
                delete $marker_data->{photo};
            }
        }
    }
    else {
        my %text;
        foreach my $lang_code (keys %{$marker_data->{details}}) {
            $text{$lang_code} = $marker_data->{details}{$lang_code};
            delete $marker_data->{details}{$lang_code};
        }
        $marker_data->{details}{text} = \%text;
        $marker_data->{details}{photo} = $marker_data->{photo} if exists $marker_data->{photo};
        delete $marker_data->{photo};
    }
    delete $marker_data->{num_plaques};
    delete $marker_data->{has_no_title} if exists $marker_data->{has_no_title};
}

say "INFO: Comparing with control data...";

my $control_json = read_file("control_data.json");
my $control_data = decode_json($control_json);
my @control_qids = keys %$control_data;

my %actual_data;
@actual_data{@control_qids} = @Data{@control_qids};

my $expected_json = JSON->new->utf8->pretty->canonical->encode($control_data);
my $actual_json   = JSON->new->utf8->pretty->canonical->encode(\%actual_data);

write_file("tmp_expected.json", $expected_json);
write_file("tmp_actual.json"  , $actual_json  );

my $diff = `diff tmp_expected.json tmp_actual.json`;
if ($diff) {
    say $diff;
    die "ERROR: Mismatch with control data";
}

unlink("tmp_expected.json", "tmp_actual.json");
write_file("data.json", encode_json(\%Data));
say "INFO: Data successfully compiled!";


sub get_initial_data_spaql_query {
    return << 'EOQ';
SELECT ?marker ?lat ?lon ?part ?quantity WHERE {
  ?marker wdt:P31 wd:Q21562164 ;
          p:P625 ?coordStatement .
  ?coordStatement psv:P625 ?coord .
  ?coord wikibase:geoLatitude ?lat ;
         wikibase:geoLongitude ?lon .
  OPTIONAL { ?coordStatement pq:P518 ?part }
  FILTER NOT EXISTS { ?coordStatement pq:P582 ?endTime }
  OPTIONAL { ?marker wdt:P1114 ?quantity }
  FILTER (!isBlank(?coord)) .
}
EOQ
}

sub process_initial_data_csv_record {

    my $marker_qid  = get_last_uri_path(shift @_);
    my $lat         = shift;
    my $lon         = shift;
    my $lang_qid    = get_last_uri_path(shift @_);
    my $num_plaques = shift;
    $num_plaques = $num_plaques ? $num_plaques + 0 : 1;

    $Data{$marker_qid} //= {};
    my $marker_data = $Data{$marker_qid};

    if (exists $marker_data->{num_plaques}) {
        if ($marker_data->{num_plaques} != $num_plaques) {
            push @error_msgs, "ERROR: [$marker_qid] Multiple values in number of plaques (P1114)";
            return;
        }
    }
    else {
        $marker_data->{num_plaques} = $num_plaques;
    }

    if (exists $marker_data->{lat}) {
        if ($marker_data->{num_plaques} == 1) {
            push @error_msgs, "ERROR: [$marker_qid] Multiple coordinates (P625) but only 1 plaque (P1114)";
            return;
        }
        push @{$marker_data->{lat}}, $lat;
        push @{$marker_data->{lon}}, $lon;
    }
    else {
        $marker_data->{lat} = [$lat];
        $marker_data->{lon} = [$lon];
    }

    if ($lang_qid and not exists LANGUAGE_CODE->{$lang_qid}) {
        push @error_msgs, "ERROR: [$marker_qid] Unrecognized language ($lang_qid)";
    }
    elsif ($lang_qid and $marker_data->{num_plaques} == 1) {
        push @error_msgs, "ERROR: [$marker_qid] Coordinates (P625) has language (P518) but only 1 plaque (P1114)";
    }
    elsif (exists $marker_data->{details}) {
        if (exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}) {
            push @error_msgs, "ERROR: [$marker_qid] Duplicate language (P518) for coordinates (P625)";
        }
        else {
            $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}} = {};
        }
    }
    elsif ($lang_qid) {
        $marker_data->{details} = {
            LANGUAGE_CODE->{$lang_qid} => {},
        };
    }
}

sub post_process_initial_data {
    while (my ($qid, $marker_data) = each %Data) {

        my $num_coordinates = @{$marker_data->{lat}};
        if ($num_coordinates > 1) {

            my $num_plaques = $marker_data->{num_plaques};
            if ($num_coordinates != $num_plaques) {
                push @error_msgs, "ERROR: [$qid] Number of coordinates (P625) does not match number of plaques (P1114)";
                next;
            }

            $marker_data->{lat} = [sum(@{$marker_data->{lat}}) / $num_plaques];
            $marker_data->{lon} = [sum(@{$marker_data->{lon}}) / $num_plaques];
        }

        $marker_data->{lat} = sprintf("%.5f", $marker_data->{lat}[0]) + 0;
        $marker_data->{lon} = sprintf("%.5f", $marker_data->{lon}[0]) + 0;
    }
}

sub get_address_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?location ?locationLabel ?address ?countryLabel ?directions
       ?admin0 ?admin0Label ?admin0Type ?admin1 ?admin1Label ?admin1Type
       ?admin2 ?admin2Label ?admin2Type ?admin3 ?admin3Label ?admin3Type
       ?islandLabel ?islandAdminType
WHERE {
  <<sparql_values>>
  ?marker wdt:P17 ?country .
  OPTIONAL { ?marker wdt:P6375 ?address }
  OPTIONAL { ?marker wdt:P276 ?location }
  OPTIONAL { ?marker wdt:P2795 ?directions }
  OPTIONAL {
    ?marker wdt:P131 ?admin0 .
    OPTIONAL {
      ?admin0 wdt:P31 ?admin0Type .
      FILTER (
        ?admin0Type = wd:Q6256     ||
        ?admin0Type = wd:Q24698    ||
        ?admin0Type = wd:Q24746    ||
        ?admin0Type = wd:Q104157   ||
        ?admin0Type = wd:Q29946056 ||
        ?admin0Type = wd:Q24764    ||
        ?admin0Type = wd:Q61878    ||
        ?admin0Type = wd:Q15634883
      )
    }
    OPTIONAL {
      ?admin0 wdt:P131 ?admin1 .
      OPTIONAL {
        ?admin1 wdt:P31 ?admin1Type .
        FILTER (
          ?admin1Type = wd:Q6256     ||
          ?admin1Type = wd:Q24698    ||
          ?admin1Type = wd:Q24746    ||
          ?admin1Type = wd:Q104157   ||
          ?admin1Type = wd:Q29946056 ||
          ?admin1Type = wd:Q24764    ||
          ?admin1Type = wd:Q61878    ||
          ?admin1Type = wd:Q15634883
        )
      }
      OPTIONAL {
        ?admin1 wdt:P131 ?admin2 .
        OPTIONAL {
          ?admin2 wdt:P31 ?admin2Type .
          FILTER (
            ?admin2Type = wd:Q6256     ||
            ?admin2Type = wd:Q24698    ||
            ?admin2Type = wd:Q24746    ||
            ?admin2Type = wd:Q104157   ||
            ?admin2Type = wd:Q29946056 ||
            ?admin2Type = wd:Q24764    ||
            ?admin2Type = wd:Q61878    ||
            ?admin2Type = wd:Q15634883
          )
        }
        OPTIONAL {
          ?admin2 wdt:P131 ?admin3 .
          OPTIONAL {
            ?admin3 wdt:P31 ?admin3Type .
            FILTER (
              ?admin3Type = wd:Q6256     ||
              ?admin3Type = wd:Q24698    ||
              ?admin3Type = wd:Q24746    ||
              ?admin3Type = wd:Q104157   ||
              ?admin3Type = wd:Q29946056 ||
              ?admin3Type = wd:Q24764    ||
              ?admin3Type = wd:Q61878

            )
          }
        }
      }
    }
  }
  OPTIONAL {
    ?marker wdt:P706 ?island .
    FILTER EXISTS { ?island wdt:P31/wdt:P279* wd:Q23442 }
    ?island wdt:P131/wdt:P31 ?islandAdminType .
    FILTER (
      ?islandAdminType = wd:Q104157   ||
      ?islandAdminType = wd:Q29946056 ||
      ?islandAdminType = wd:Q24764    ||
      ?islandAdminType = wd:Q15634883 ||
      ?islandAdminType = wd:Q61878
    )
  }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
}
EOQ
}

sub process_address_data_csv_record {

    my $marker_qid        = get_last_uri_path(shift @_);
    my $location_qid      = get_last_uri_path(shift @_);
    my $location_label    = shift;
    my $street_address    = shift;
    my $country           = shift;
    my $directions        = shift;
    my $admin0_qid        = shift;
    my $admin0_label      = shift;
    my $admin0_type       = shift;
    my $admin1_qid        = shift;
    my $admin1_label      = shift;
    my $admin1_type       = shift;
    my $admin2_qid        = shift;
    my $admin2_label      = shift;
    my $admin2_type       = shift;
    my $admin3_qid        = shift;
    my $admin3_label      = shift;
    my $admin3_type       = shift;
    my $island_label      = shift;
    my $island_admin_type = get_last_uri_path(shift @_);

    my @admin_qids   = ($admin0_qid  , $admin1_qid  , $admin2_qid  , $admin3_qid  );
    my @admin_labels = ($admin0_label, $admin1_label, $admin2_label, $admin3_label);
    my @admin_types  = ($admin0_type , $admin1_type , $admin2_type , $admin3_type );

    foreach (0..3) {
        $admin_qids [$_] = get_last_uri_path($admin_qids [$_]);
        $admin_types[$_] = get_last_uri_path($admin_types[$_]);
        if (exists ADDRESS_LABEL_REPLACEMENT->{$admin_qids[$_]}) {
            $admin_labels[$_] = ADDRESS_LABEL_REPLACEMENT->{$admin_qids[$_]};
        }
    }

    my $marker_data = $Data{$marker_qid};

    # Address generation logic matches the Historical Markers Map app
    my @address_parts;
    my @macro_address_parts;
    return if $location_qid and exists(SKIP_ADDRESS_HAVING->{$location_qid});
    push @address_parts, $location_label if $location_label and not exists SKIPPED_ADDRESS_LABELS->{$location_qid};
    push @address_parts, $street_address if $street_address;
    foreach my $level (0..3) {
        return if $admin_qids[$level] and exists(SKIP_ADDRESS_HAVING->{$admin_qids[$level]});
        if (
            $admin_labels[$level] and
            $admin_types[$level] ne COUNTRY_QID and
            (
                $level == 0 or
                (
                    $admin_types[$level - 1] ne PROVINCE_QID and
                    $admin_types[$level - 1] ne REGION_QID   and
                    (
                        (
                            $admin_types[$level - 1] ne CITY_QID and
                            $admin_types[$level - 1] ne HUC_QID
                        ) or
                        $admin_types[$level] ne REGION_QID or
                        $admin_qids[$level] eq METRO_MANILA_QID
                    )
                )
            )
        ) {
            if (not exists(SKIPPED_ADDRESS_LABELS->{$admin_qids[$level]})) {
                if ($island_label and $island_admin_type eq $admin_types[$level]) {
                    push @address_parts, $island_label;
                }
                push @address_parts, $admin_labels[$level];
            }
            if (
                (
                    scalar @macro_address_parts > 0 or
                    $admin_types[$level] eq HUC_QID or
                    $admin_types[$level] eq CITY_QID or
                    $admin_types[$level] eq MUNICIPALITY_QID or
                    $admin_types[$level] eq DISTRICT_OF_MANILA_QID
                )
                and not
                (
                    $level > 0 and
                    $admin_qids[$level - 1] eq MANILA_QID and
                    $admin_qids[$level] eq METRO_MANILA_QID
                )
            ) {
                push @macro_address_parts, $admin_labels[$level];
            }
        }
        if ($admin_types[$level] eq REGION_QID) {

            my $region_name = $admin_labels[$level];

            # Apply region name substitutions
            $region_name = "Bangsamoro" if $region_name eq "Bangsamoro Autonomous Region";
            $region_name = "Cordillera" if $region_name eq "Cordillera Administrative Region";

            if (exists $marker_data->{region}) {
                # Assume that a marker can only have at most 2 regions
                $marker_data->{region} = [$marker_data->{region}, $region_name];
            }
            else {
                $marker_data->{region} = $region_name;
            }
        }
    }
    if ($country ne "Philippines") {
        push @address_parts, $country;
        if (not OVERSEAS_MACRO_ADDRESS->{$marker_qid}) {
            push @error_msgs, "ERROR: [$marker_qid] Foreign marker has no macro address";
            return;
        }
        $marker_data->{macroAddress} = OVERSEAS_MACRO_ADDRESS->{$marker_qid};
        $marker_data->{region} = "Overseas";
    }
    else {
        $marker_data->{macroAddress} = join ", ", @macro_address_parts;
    }
    my $full_address = join ", ", @address_parts;
    $full_address =~ s/(^|, )([^, ]*)(?:, \2)+(, |$)/$1$2$3/g;

    if (exists $marker_data->{address}) {
        warn "WARNING: [$marker_qid] Multiple addresses";
        $marker_data->{address} .= " / $full_address" ;
    }
    else {
        $marker_data->{address} = $full_address;
    }

    $marker_data->{locDesc} = $directions if $directions;
}

sub get_title_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?markerLabel ?title ?titleLang ?targetLang ?subtitle ?titleNoValue
WHERE {
  <<sparql_values>>
  ?marker p:P1476 ?titleStatement .
  OPTIONAL {
    ?titleStatement ps:P1476 ?title .
    BIND(LANG(?title) AS ?titleLang) .
    OPTIONAL { ?titleStatement pq:P518 ?targetLang }
    OPTIONAL { ?titleStatement pq:P1680 ?subtitle }
  }
  OPTIONAL {
    ?titleStatement a ?titleNoValue .
    FILTER (?titleNoValue = wdno:P1476)
    OPTIONAL { ?titleStatement pq:P518 ?targetLang }
    ?marker rdfs:label ?markerLabel .
    FILTER (LANG(?markerLabel) = "en")
  }
}
EOQ
}

sub process_title_data_csv_record {

    my $marker_qid      = get_last_uri_path(shift @_);
    my $label           = shift;
    my $title           = shift;
    my $title_lang_code = shift;
    my $target_lang_qid = get_last_uri_path(shift @_);
    my $subtitle        = shift;
    my $has_no_title    = shift;

    my $marker_data = $Data{$marker_qid};

    if ($target_lang_qid and not exists LANGUAGE_CODE->{$target_lang_qid}) {
        push @error_msgs, "ERROR: [$marker_qid] Unrecognized language ($target_lang_qid)";
        return;
    }
    if ($title_lang_code and not exists VALID_LANGUAGES->{$title_lang_code}) {
        push @error_msgs, "ERROR: [$marker_qid] Unrecognized language ($title_lang_code)";
        return;
    }
    if ($has_no_title) {
        if (
            exists $marker_data->{details} and
            scalar keys %{$marker_data->{details}} > 0 and
            not $target_lang_qid
        ) {
            push @error_msgs, "ERROR: [$marker_qid] Marker is stated as both having no title and having a title";
            return;
        }
        if ($target_lang_qid) {
            if (not exists $marker_data->{details}) {
                $marker_data->{details} = {};
                $marker_data->{details}{LANGUAGE_CODE->{$target_lang_qid}} = {
                    inscription => '',  # Provisionally set inscription as missing
                };
            }
        }
        else {
            $marker_data->{has_no_title} = 1;
            $marker_data->{name} = $label =~ s/ historical marker$//r;
        }
    }
    else {
        if (exists $marker_data->{has_no_title}) {
            push @error_msgs, "ERROR: [$marker_qid] Marker is stated as both having no title and having a title";
            return;
        }
        $marker_data->{details} = {} if not exists $marker_data->{details};
        my $current_lang = (
            LANGUAGE_CODE->{$target_lang_qid} and
            $title_lang_code ne LANGUAGE_CODE->{$target_lang_qid}
        ) ? LANGUAGE_CODE->{$target_lang_qid} : $title_lang_code;
        $marker_data->{details}{$current_lang} = {
            title       => $title,
            inscription => '',  # Provisionally set inscription as missing
        };
        $marker_data->{details}{$current_lang}{subtitle} = $subtitle if $subtitle;
    }
}

sub post_process_title_data {
    while (my ($qid, $marker_data) = each %Data) {

        next if $marker_data->{has_no_title};
        if (
            scalar keys %{$marker_data->{details}} > 1 and
            $marker_data->{num_plaques} > 1 and
            scalar keys %{$marker_data->{details}} != $marker_data->{num_plaques}
        ) {
            push @error_msgs, "ERROR: [$qid] Number of languages does not match number of plaques (P1114)";
            next;
        }
        if (scalar keys %{$marker_data->{details}} == 0) {
            push @error_msgs, "ERROR: [$qid] Marker has no title information (P1476)";
            next;
        }

        foreach my $lang_code (@{(ORDERED_LANGUAGES)}) {
            if (exists $marker_data->{details}{$lang_code}) {
                $marker_data->{name} = $marker_data->{details}{$lang_code}{title};
                # Remove quotation marks from El Deposito
                if ($marker_data->{name} =~ /^“(.+)”$/) {
                    $marker_data->{name} = $1;
                }
                # Remove line breaks
                $marker_data->{name} =~ s/<br>/ /;
                last;
            }
        }
    }
}

sub get_inscription_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?inscription ?inscriptionLang ?inscriptionNoValue
WHERE {
  <<sparql_values>>
  ?marker p:P1684 ?inscriptionStatement .
  OPTIONAL {
    ?inscriptionStatement ps:P1684 ?inscription .
    BIND(LANG(?inscription) AS ?inscriptionLang) .
  }
  OPTIONAL {
    ?inscriptionStatement a ?inscriptionNoValue .
    FILTER (?inscriptionNoValue = wdno:P1684)
  }
}
EOQ
}

sub process_inscription_data_csv_record {

    my $marker_qid         = get_last_uri_path(shift @_);
    my $inscription        = shift;
    my $lang_code          = shift;
    my $has_no_inscription = shift;

    my $marker_data = $Data{$marker_qid};

    if ($has_no_inscription) {
        if (exists $marker_data->{has_no_title}) {
            push @error_msgs, "ERROR: [$marker_qid] Marker has no title and inscription";
            return;
        }
        foreach my $l10n_detail (values %{$marker_data->{details}}) {
            delete $l10n_detail->{inscription};
        }
    }
    else {
        process_inscription($marker_qid, $inscription, $lang_code);
    }
}

sub query_long_inscription {

    my $pm          = shift;
    my $qid         = shift;
    my $marker_data = shift;

    # Check if there are missing inscriptions
    my $has_missing_inscription;
    foreach my $l10n_detail (values %{$marker_data->{details}}) {
        if (exists $l10n_detail->{inscription} and $l10n_detail->{inscription} eq '') {
            $has_missing_inscription = 1;
            last;
        }
    }
    return if not $has_missing_inscription;

    $pm->start($qid) and return;

    say "INFO: [$qid] Attempting to fetch long inscriptions" if $Log_Level > 1;
    my $ua = LWP::UserAgent->new;
    $ua->default_header(Accept => "application/sparql-results+json");
    my $response = $ua->post(WIKIDATA_API_URL, {
        format => "json",
        action => "query",
        prop   => "revisions",
        rvprop => "content",
        titles => "Talk:" . $qid,
    });
    my $response_raw = decode_json($response->decoded_content);
    my $page_id = +(keys %{$response_raw->{query}{pages}})[0];
    if ($page_id == -1) {
        $pm->finish(0);
    }
    else {
        my @return_data;
        my $contents = $response_raw->{query}{pages}{$page_id}{revisions}[0]{"*"};
        while ($contents =~ /\{\{\s*LongInscription(.+?)}}/sg) {
            my $template_text = $1;
            my ($lang_qid   ) = $template_text =~ /\|\s*langqid\s*=\s*(Q[0-9]+)/s;
            my ($inscription) = $template_text =~ /\|\s*inscription\s*=\s*(.+?)(?:\||$)/s;
            if (not exists LANGUAGE_CODE->{$lang_qid}) {
                push @error_msgs, "ERROR: [$qid] Inscription is in an unrecognized language ($lang_qid)";
                return;
            }
            if (length $inscription <= WIKIDATA_MAX_STR_LENGTH) {
                warn "WARNING: [$qid] \"Long\" inscription is <= " . WIKIDATA_MAX_STR_LENGTH . " characters in length";
            }
            push @return_data, [LANGUAGE_CODE->{$lang_qid}, $inscription];
        }
        $pm->finish(0, \@return_data);
    }
}

sub process_long_inscription {
    my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_ref) = @_;
    return if not defined $data_ref;
    foreach my $inscription_datum (@$data_ref) {
        my ($lang_code, $inscription) = @$inscription_datum;
        process_inscription($ident, $inscription, $lang_code);
    }
}

sub get_unveiling_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?date ?datePrecision ?part
WHERE {
  <<sparql_values>>
  ?marker p:P571 ?dateStatement .
  OPTIONAL { ?dateStatement pq:P518 ?part }
  FILTER NOT EXISTS { ?dateStatement pq:P582 ?endTime }
  ?dateStatement psv:P571 ?dateValue .
  ?dateValue wikibase:timeValue ?date .
  ?dateValue wikibase:timePrecision ?datePrecision .
}
EOQ
}

sub process_unveiling_data_csv_record {

    my $marker_qid = get_last_uri_path(shift @_);
    my $date       = shift;
    my $precision  = shift;
    my $lang_qid   = get_last_uri_path(shift @_);

    my $marker_data = $Data{$marker_qid};

    if ($precision < 9 or 11 < $precision) {
        push @error_msgs, "ERROR: [$marker_qid] Date has an unexpected precision";
    }
    if ($lang_qid) {
        if ($marker_data->{num_plaques} == 1) {
            push @error_msgs, "ERROR: [$marker_qid] Date (P571) has a language (P518) but there is only 1 plaque (P1114)";
            return;
        }
        if (not exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}) {
            push @error_msgs, "ERROR: [$marker_qid] Date (P571) applies an extra language (P518)";
            return;
        }
        if (exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}{date}) {
            push @error_msgs, "ERROR: [$marker_qid] Date (P571) has a duplicate language (P518)";
            return;
        }
        $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}{date} = substr($date, 0, $precision == 11 ? 10 : 4);
        $marker_data->{date} = JSON::true;
    }
    else {
        if (exists $marker_data->{details}{date}) {
            push @error_msgs, "ERROR: [$marker_qid] There is more than 1 date (P571)";
            return;
        }
        $marker_data->{date} = substr($date, 0, $precision == 11 ? 10 : 4);
    }
}

sub get_photo_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?image ?targetLang ?ordinal ?vicinityImage
WHERE {
  <<sparql_values>>
  ?marker p:P18 ?imageStatement .
  FILTER NOT EXISTS { ?imageStatement pq:P582 ?endTime }
  OPTIONAL {
    ?imageStatement ps:P18 ?image .
    OPTIONAL { ?imageStatement pq:P518 ?targetLang }
    OPTIONAL { ?imageStatement pq:P1545 ?ordinal }
    FILTER NOT EXISTS { ?imageStatement pq:P3831 wd:Q16968816 }
  }
  OPTIONAL {
    ?imageStatement ps:P18 ?vicinityImage .
    FILTER EXISTS { ?imageStatement pq:P3831 wd:Q16968816 }
  }
}
EOQ
}

sub process_photo_data_csv_record {

    my $marker_qid         = get_last_uri_path(shift @_);
    my $photo_filename     = decode("UTF-8", uri_unescape(get_last_uri_path(shift @_)));
    my $lang_qid           = get_last_uri_path(shift @_);
    my $ordinal            = shift;
    my $loc_photo_filename = decode("UTF-8", uri_unescape(get_last_uri_path(shift @_)));

    my $marker_data = $Data{$marker_qid};

    if ($photo_filename) {
        my $photo_record = {
            file   => $photo_filename,
            credit => undef,
        };
        if ($marker_data->{num_plaques} == 1) {
            if (exists $marker_data->{photo}) {
                push @error_msgs, "ERROR: [$marker_qid] Multiple photos (P18) but there is only 1 plaque (P1114)";
                return;
            }
            $marker_data->{photo} = $photo_record;
        }
        else {
            if (not $lang_qid and not $ordinal) {
                push @error_msgs, "ERROR: [$marker_qid] Missing language (P518) or ordinal (P1545) for marker with multiple plaques (P1114)";
                return;
            }
            if ($lang_qid) {
                if (not exists LANGUAGE_CODE->{$lang_qid}) {
                    push @error_msgs, "ERROR: [$marker_qid] Photo is in an unrecognized language ($lang_qid) (P518)";
                    return;
                }
                my $lang_code = LANGUAGE_CODE->{$lang_qid};
                if (not exists $marker_data->{details}{$lang_code}) {
                    push @error_msgs, "ERROR: [$marker_qid] Photo is in an extra language ($lang_code) (P518)";
                    return;
                }
                if (exists $marker_data->{details}{$lang_code}{photo}) {
                    push @error_msgs, "ERROR: [$marker_qid] Duplicate photo language ($lang_code) (P518)";
                    return;
                }
                $marker_data->{details}{$lang_code}{photo} = $photo_record;
            }
            else {
                if (not exists $marker_data->{photo}) {
                    $marker_data->{photo} = [];
                }
                $marker_data->{photo}[$ordinal + 0] = $photo_record;
            }
        }
    }
    elsif ($loc_photo_filename) {
        if (exists $marker_data->{locPhoto}) {
            push @error_msgs, "ERROR: [$marker_qid] Multiple vicinity photos (P18 P3831 wd:Q16968816)";
            return;
        }
        $marker_data->{locPhoto} = {
            file   => $loc_photo_filename,
            credit => undef,
        };
    }
}

sub query_photo_metadata {

    my $pm          = shift;
    my $qid         = shift;
    my $marker_data = shift;

    if ($marker_data->{locPhoto}) {
        if ($pm->start($qid) == 0) {
            my $photo_data = get_photo_data($qid, $marker_data->{locPhoto}{file});
            $pm->finish(0, ["locPhoto", $photo_data]);
        }
    }
    if ($marker_data->{num_plaques} == 1) {
        if ($marker_data->{photo}) {
            if ($pm->start($qid) == 0) {
                my $photo_data = get_photo_data($qid, $marker_data->{photo}{file});
                $pm->finish(0, ["photo", $photo_data]);
            }
        }
    }
    else {
        if ($marker_data->{photo}) {
            foreach my $idx (1..scalar @{$marker_data->{photo}}) {
                if ($marker_data->{photo}[$idx]) {
                    if ($pm->start($qid) == 0) {
                        my $photo_data = get_photo_data($qid, $marker_data->{photo}[$idx]{file});
                        $pm->finish(0, [$idx, $photo_data]);
                    }
                }
            }
        }
        else {
            foreach my $lang_code (keys %{$marker_data->{details}}) {
                if ($marker_data->{details}{$lang_code}{photo}) {
                    if ($pm->start($qid) == 0) {
                        my $photo_data = get_photo_data($qid, $marker_data->{details}{$lang_code}{photo}{file});
                        $pm->finish(0, [$lang_code, $photo_data]);
                    }
                }
            }
        }
    }
}

sub process_photo_metadata {
    my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_ref) = @_;
    return if not defined $data_ref;
    my ($type, $raw_data) = @$data_ref;
    my ($width, $height, $credit) = split /\|/, $raw_data, 3;
    my $photo_data;
    if ($type eq "locPhoto") {
        $photo_data = $Data{$ident}{locPhoto};
    }
    elsif ($type eq "photo") {
        $photo_data = $Data{$ident}{photo};
    }
    elsif ($type =~ /^\d+$/) {
        $photo_data = $Data{$ident}{photo}[$type];
    }
    else {
        $photo_data = $Data{$ident}{details}{$type}{photo};
    }
    $photo_data->{width } = $width  + 0;
    $photo_data->{height} = $height + 0;
    $photo_data->{credit} = $credit;
}

sub get_commemorates_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?commemoratesLabel ?commemoratesArticle
WHERE {
  <<sparql_values>>
  ?marker wdt:P547 ?commemorates .
  ?commemorates rdfs:label ?commemoratesLabel .
  FILTER (LANG(?commemoratesLabel) = "en")
  ?commemoratesArticle schema:about ?commemorates ;
                       schema:isPartOf <https://en.wikipedia.org/> .
}
EOQ
}

sub process_commemorates_data_csv_record {

    my $marker_qid = get_last_uri_path(shift @_);
    my $label      = shift;
    my $title      = decode("UTF-8", uri_unescape(get_last_uri_path(shift @_))) =~ s/_/ /gr;

    my $marker_data = $Data{$marker_qid};

    $marker_data->{wikipedia} //= {};
    if ($label eq $title) {
        $marker_data->{wikipedia}{$label} = JSON::true;
    }
    else {
        $marker_data->{wikipedia}{$label} = $title;
    }
}

sub get_category_data_sparql_query {
    return << 'EOQ';
SELECT ?marker ?commonsCategory
WHERE {
  <<sparql_values>>
  ?commonsCategory schema:about ?marker ;
                   schema:isPartOf <https://commons.wikimedia.org/> .
}
EOQ
}

sub process_category_data_csv_record {
    my $marker_data = $Data{get_last_uri_path(shift @_)};
    $marker_data->{commons} = substr(shift @_, 44);
}


sub get_last_uri_path {
    my $uri = shift;
    return +(split(/\//, $uri))[-1] if $uri;
    return "";
}

sub parse_csv {
    my $input = shift;
    my $csv_agent = Text::CSV->new({ binary => 1 });
    my @output;
    foreach my $row (split(/[\n\r\f]+/, $input)) {
        $csv_agent->parse($row);
        push @output, [$csv_agent->fields];
    }
    shift @output;  # Discard header row
    return @output;
}

sub process_inscription {

    my $marker_qid  = shift;
    my $inscription = shift;
    my $lang_code   = shift;

    # HTML-format the inscription
    $inscription =~ s/ +/ /g;
    $inscription =~ s/^\s+//g;
    $inscription =~ s/\s+$//g;
    $inscription =~ s{<br */?>\s*<br */?>}{</p><p>}g;
    $inscription = "<p>$inscription</p>";

    my $marker_data = $Data{$marker_qid};

    if ($lang_code and not exists VALID_LANGUAGES->{$lang_code}) {
        push @error_msgs, "ERROR: [$marker_qid] Inscription is in an unrecognized language ($lang_code)";
    }
    if (
        not exists $marker_data->{has_no_title} and
        $lang_code and
        not exists $marker_data->{details}{$lang_code}
    ) {
        push @error_msgs, "ERROR: [$marker_qid] Inscription is in an extra language ($lang_code)";
    }
    if (not exists $marker_data->{details}) {
        if (not exists $marker_data->{has_no_title}) {
            push @error_msgs, "ERROR: [$marker_qid] Weird data inconsistency error";
        }
        $marker_data->{details} = {};
    }
    if (not exists $marker_data->{details}{$lang_code}) {
        if (not exists $marker_data->{has_no_title}) {
            push @error_msgs, "ERROR: [$marker_qid] Weird data inconsistency error";
        }
        $marker_data->{details}{$lang_code} = { inscription => $inscription }
    }
    else {
        $marker_data->{details}{$lang_code}{inscription} = $inscription;
    }

    return;
}

sub get_photo_data {

    my $qid   = shift;
    my $photo = shift;

    say "INFO: [$qid] Fetching credit for $photo" if $Log_Level > 1;

    my $ua = LWP::UserAgent->new;
    $ua->default_header(Accept => "application/sparql-results+json");
    my $response = $ua->post(COMMONS_API_URL, {
        format => "json",
        action => "query",
        prop   => "imageinfo",
        iiprop => "extmetadata|size",
        titles => "File:" . $photo,
    });
    my $response_raw = decode_json($response->decoded_content);
    my $page_id = +(keys %{$response_raw->{query}{pages}})[0];
    my $info = $response_raw->{query}{pages}{$page_id}{imageinfo}[0];
    my $width    = $info->{width      };
    my $height   = $info->{height     };
    my $metadata = $info->{extmetadata};
    my $author = $metadata->{Artist}{value};
    if (not $author) {
        say "WARN: [$qid] Photo author is missing";
    }
    $author =~ s/<[^>]+>//g;
    $author =~ s/\n//g;
    my $license = "";
    if (exists $metadata->{AttributionRequired} and $metadata->{AttributionRequired}{value} eq "true") {
        $license = $metadata->{LicenseShortName}{value};
        $license =~ s/ / /g;  # non-breaking space
        $license =~ s/-/‑/g;  # Non-breaking hyphen
        $license = " {$license}";
    }
    return "$width|$height|$author$license";
}
