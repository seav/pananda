#!/usr/bin/env perl

use utf8;
use warnings;
use 5.012;
use feature 'unicode_strings';

use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use Encode;
use File::Slurp;
use JSON::MaybeXS;
use List::Util qw(sum);
use LWP::UserAgent ();
use Term::ProgressBar;
use Text::CSV;
use URI::Escape;

## no critic (ProhibitConstantPragma)
use constant {
    LANGUAGE_CODE             => {
        Q1860  => 'en',
        Q34057 => 'tl',
        Q33239 => 'ceb',
        Q35936 => 'ilo',
        Q36121 => 'pam',
        Q1321  => 'es',
        Q188   => 'de',
        Q150   => 'fr',
    },
    ORDERED_LANGUAGES         => ['en', 'tl', 'ceb', 'ilo', 'pam', 'es', 'de', 'fr'],
    COUNTRY_QID               => 'Q6256',
    REGION_QID                => 'Q24698',
    PROVINCE_QID              => 'Q24746',
    HUC_QID                   => 'Q29946056',
    CITY_QID                  => 'Q104157',
    MUNICIPALITY_QID          => 'Q24764',
    METRO_MANILA_QID          => 'Q13580',
    MANILA_QID                => 'Q1461',
    DISTRICT_OF_MANILA_QID    => 'Q15634883',
    WDQS_URL                  => 'https://query.wikidata.org/sparql',
    COMMONS_API_URL           => 'https://commons.wikimedia.org/w/api.php',
    WIKIDATA_API_URL          => 'https://www.wikidata.org/w/api.php',
    WIKIDATA_MAX_STR_LENGTH   => 1500,
    SKIPPED_ADDRESS_LABELS    => {
        Q2863958  => 1,  # arrondissement of Paris
        Q90870    => 1,  # Arrondissement of Brussels-Capital
        Q240      => 1,  # Brussels-Capital Region
        Q90948    => 1,  # Arrondissement of Ghent
        Q8165     => 1,  # Karlsruhe Government Region
        Q2013767  => 1,  # Mitte (locality in Mitte)
        Q132480   => 1,  # Kantō region
        Q3551781  => 1,  # District of Columbia
    },
    SKIP_ADDRESS_HAVING => {
        Q16665915 => 1,  # Metropolis of Greater Paris
        Q212429   => 1,  # Metropolitan France
    },
    ADDRESS_LABEL_REPLACEMENT => {
        Q245546 => '6th arrondissement',
    },
    OVERSEAS_MACRO_ADDRESS    => {
        Q30130266 => 'Tokyo, Japan',
        Q79945262 => 'Tokyo, Japan',
        Q52878121 => 'Dezhou, Shandong, China',
        Q30130018 => 'Sydney, New South Wales, Australia',
        Q30131050 => 'Paris, France',
        Q30127147 => 'Ghent, Belgium',
        Q28874593 => 'Brussels, Belgium',
        Q26709080 => 'Wilhelmsfeld, Germany',
        Q23854678 => 'Berlin, Germany',
        Q56810749 => 'Vienna, Austria',
        Q63349729 => 'Washington, D.C., United States',
        Q30133244 => 'Chicago, Illinois, United States',
        Q30129474 => 'Carson, California, United States',
        Q60232924 => 'Jersey City, New Jersey, United States',
        Q60458584 => 'Waipahu, Hawaii, United States',
        Q52984027 => 'Guam, United States',
    },
};
use constant VALID_LANGUAGES => { map {($_, 1)} @{(ORDERED_LANGUAGES)} };
## use critic (ProhibitConstantPragma)

binmode STDIN , ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $Log_Level = 1;

my %Data;
my %Photo_Metadata;
my @Error_Msgs;

query_data();
finalize_data();
check_against_control_data();

write_file('data.json', encode_json(\%Data));
say 'INFO: Data successfully compiled!';

exit;

# ===================================================================
# MAIN SUBROUTINES
# ===================================================================

sub query_data {

    my @steps = (
        {
            title                => 'initial marker data with coordinates',
            sparql_query         => get_initial_data_spaql_query(),
            csv_record_processor => \&process_initial_data_csv_record,
            post_processor       => \&post_process_initial_data,
            set_helper_vars      => 1,
        },
        {
            title                => 'address data',
            sparql_query         => get_address_data_sparql_query(),
            csv_record_processor => \&process_address_data_csv_record,
        },
        {
            title                => 'title data',
            sparql_query         => get_title_data_sparql_query(),
            csv_record_processor => \&process_title_data_csv_record,
            post_processor       => \&post_process_title_data,
        },
        {
            title                => 'short inscription data',
            sparql_query         => get_inscription_data_sparql_query(),
            csv_record_processor => \&process_inscription_data_csv_record,
        },
        {
            is_mwapi_step        => 1,
            title                => 'long inscription data',
            sparql_query         => get_long_inscription_sparql_query(),
            titles_generator     => \&get_long_inscription_titles,
            csv_record_processor => \&process_long_inscription_data_csv_record,
        },
        {
            title                => 'unveiling date data',
            sparql_query         => get_unveiling_data_sparql_query(),
            csv_record_processor => \&process_unveiling_data_csv_record,
        },
        {
            title                => 'photo data',
            sparql_query         => get_photo_data_sparql_query(),
            csv_record_processor => \&process_photo_data_csv_record,
        },
        {
            is_mwapi_step        => 1,
            title                => 'photo metadata',
            sparql_query         => get_photo_metadata_sparql_query(),
            titles_generator     => \&get_photo_metadata_titles,
            csv_record_processor => \&process_photo_metadata_csv_record,
        },
        {
            title                => 'commemorates-Wikipedia data',
            sparql_query         => get_commemorates_data_sparql_query(),
            csv_record_processor => \&process_commemorates_data_csv_record,
        },
        {
            title                => 'Commons category data',
            sparql_query         => get_category_data_sparql_query(),
            csv_record_processor => \&process_category_data_csv_record,
        },
    );

    my $sparql_values;
    my $num_markers;

    my $ua = LWP::UserAgent->new;
    $ua->default_header(Accept => 'text/csv');

    foreach my $step (@steps) {

        say "INFO: Fetching and processing $step->{title}...";

        my @queries;
        my $sparql_query = $step->{sparql_query};
        if (exists $step->{is_mwapi_step}) {
            my $titles = $step->{titles_generator}->();
            if (ref($titles) eq 'ARRAY') {
                @queries = map { $sparql_query =~ s/<<titles>>/$_/r } @$titles;
            }
            else {
                push @queries, $sparql_query =~ s/<<titles>>/$titles/r;
            }
        }
        else {
            push @queries, $sparql_query =~ s/<<sparql_values>>/$sparql_values/r;
        }

        my $num_queries = scalar @queries;
        my $progress;
        $progress = Term::ProgressBar->new({count => $num_queries}) if $Log_Level == 1 and $num_queries > 1;
        my $num_queries_processed = 0;
        foreach my $query (@queries) {
            my $response = $ua->post(WDQS_URL, {query => $query});
            foreach my $csv_record (parse_csv($response->decoded_content)) {
                $step->{csv_record_processor}->($csv_record);
            }
            $progress->update(++$num_queries_processed) if $progress and $Log_Level == 1;
        }

        $step->{post_processor}->() if exists $step->{post_processor};

        if (@Error_Msgs) {
            die join("\n", @Error_Msgs) . "\n";
        }

        if (exists $step->{set_helper_vars}) {
            $num_markers = scalar keys %Data;
            my $qid_list = join(' ', map { "wd:$_" } keys %Data);
            $sparql_values = "VALUES ?marker { $qid_list }";
        }
    }

    return;
}

# -------------------------------------------------------------------

sub finalize_data {
    say 'INFO: Marshalling data structure into final format...';
    foreach my $marker_data (values %Data) {
        if (
            $marker_data->{num_plaques} > 1 or
            scalar keys %{$marker_data->{details}} == 1
        ) {
            if (ref($marker_data->{photo}) eq 'ARRAY') {
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
                    ref($marker_data->{photo}) eq 'ARRAY'
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
    return;
}

# -------------------------------------------------------------------

sub check_against_control_data {

    say 'INFO: Comparing with control data...';

    my $control_json = read_file('control_data.json');
    my $control_data = decode_json($control_json);
    my @control_qids = keys %$control_data;

    my %actual_data;
    @actual_data{@control_qids} = @Data{@control_qids};

    my $expected_json = JSON->new->utf8->pretty->canonical->encode($control_data);
    my $actual_json   = JSON->new->utf8->pretty->canonical->encode(\%actual_data);

    write_file('tmp_expected.json', $expected_json);
    write_file('tmp_actual.json'  , $actual_json  );

    my $diff = `diff tmp_expected.json tmp_actual.json`;
    if ($diff) {
        say $diff;
        die 'ERROR: Mismatch with control data';
    }

    unlink('tmp_expected.json', 'tmp_actual.json');

    return;
}

# ===================================================================
# QUERY_DATA SUBROUTINES
# ===================================================================

sub get_initial_data_spaql_query {
    return << 'EOQ';
SELECT ?markerQid ?lat ?lon ?langQid ?quantity WHERE {
  ?marker wdt:P31 wd:Q21562164 ;
          p:P625 ?coordStatement .
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?coordStatement psv:P625 ?coord .
  ?coord wikibase:geoLatitude ?lat ;
         wikibase:geoLongitude ?lon .
  OPTIONAL {
    ?coordStatement pq:P518 ?lang .
    BIND(SUBSTR(STR(?lang), 32) AS ?langQid) .
  }
  FILTER NOT EXISTS { ?coordStatement pq:P582 ?endTime }
  OPTIONAL { ?marker wdt:P1114 ?quantityRaw }
  BIND(IF(BOUND(?quantityRaw), ?quantityRaw, 1) AS ?quantity) .
  FILTER (!ISBLANK(?coord)) .
}
EOQ
}

# -------------------------------------------------------------------

sub process_initial_data_csv_record {

    my $csv_record = shift;
    my ($qid, $lat, $lon, $lang_qid, $num_plaques) = @$csv_record;
    $num_plaques += 0;

    $Data{$qid} //= {};
    my $marker_data = $Data{$qid};

    if (exists $marker_data->{num_plaques}) {
        if ($marker_data->{num_plaques} != $num_plaques) {
            log_error($qid, "Multiple values in number of plaques (P1114)");
            return;
        }
    }
    else {
        $marker_data->{num_plaques} = $num_plaques;
    }

    if (exists $marker_data->{lat}) {
        if ($marker_data->{num_plaques} == 1) {
            log_error($qid, "Multiple coordinates (P625) but only 1 plaque (P1114)");
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
        log_error($qid, "Unrecognized language ($lang_qid)");
    }
    elsif ($lang_qid and $marker_data->{num_plaques} == 1) {
        log_error($qid, "Coordinates (P625) has language (P518) but only 1 plaque (P1114)");
    }
    elsif (exists $marker_data->{details}) {
        if (exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}) {
            log_error($qid, "Duplicate language (P518) for coordinates (P625)");
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

    return;
}

# -------------------------------------------------------------------

# Check that the number of coordinates matches the number of plaques
# and if the number of coordinates is more than 1, average them
sub post_process_initial_data {
    while (my ($qid, $marker_data) = each %Data) {

        my $num_coordinates = @{$marker_data->{lat}};
        if ($num_coordinates > 1) {

            my $num_plaques = $marker_data->{num_plaques};
            if ($num_coordinates != $num_plaques) {
                log_error($qid, "Number of coordinates (P625) does not match number of plaques (P1114)");
                next;
            }

            $marker_data->{lat} = [sum(@{$marker_data->{lat}}) / $num_plaques];
            $marker_data->{lon} = [sum(@{$marker_data->{lon}}) / $num_plaques];
        }

        $marker_data->{lat} = sprintf('%.5f', $marker_data->{lat}[0]) + 0;
        $marker_data->{lon} = sprintf('%.5f', $marker_data->{lon}[0]) + 0;
    }
    return;
}

# ===================================================================

sub get_address_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?locationQid ?locationLabel ?address ?countryLabel ?directions
       ?admin0Qid ?admin0Label ?admin0TypeQid
       ?admin1Qid ?admin1Label ?admin1TypeQid
       ?admin2Qid ?admin2Label ?admin2TypeQid
       ?admin3Qid ?admin3Label ?admin3TypeQid
       ?islandLabel ?islandAdminTypeQid
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker wdt:P17 ?country .
  OPTIONAL { ?marker wdt:P6375 ?address }
  OPTIONAL {
    ?marker wdt:P276 ?location .
    BIND(SUBSTR(STR(?location), 32) AS ?locationQid) .
  }
  OPTIONAL { ?marker wdt:P2795 ?directions }
  OPTIONAL {
    ?marker wdt:P131 ?admin0 .
    BIND(SUBSTR(STR(?admin0), 32) AS ?admin0Qid) .
    OPTIONAL {
      ?admin0 wdt:P31 ?admin0Type .
      BIND(SUBSTR(STR(?admin0Type), 32) AS ?admin0TypeQid) .
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
      BIND(SUBSTR(STR(?admin1), 32) AS ?admin1Qid) .
      OPTIONAL {
        ?admin1 wdt:P31 ?admin1Type .
        BIND(SUBSTR(STR(?admin1Type), 32) AS ?admin1TypeQid) .
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
        BIND(SUBSTR(STR(?admin2), 32) AS ?admin2Qid) .
        OPTIONAL {
          ?admin2 wdt:P31 ?admin2Type .
          BIND(SUBSTR(STR(?admin2Type), 32) AS ?admin2TypeQid) .
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
          BIND(SUBSTR(STR(?admin3), 32) AS ?admin3Qid) .
          OPTIONAL {
            ?admin3 wdt:P31 ?admin3Type .
            BIND(SUBSTR(STR(?admin3Type), 32) AS ?admin3TypeQid) .
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
    BIND(SUBSTR(STR(?islandAdminType), 32) AS ?islandAdminTypeQid) .
  }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
}
EOQ
}

# -------------------------------------------------------------------

sub process_address_data_csv_record {

    my $csv_record = shift;
    my (
        $qid, $location_qid, $location_label,
        $street_address, $country, $directions,
        $admin0_qid, $admin0_label, $admin0_type,
        $admin1_qid, $admin1_label, $admin1_type,
        $admin2_qid, $admin2_label, $admin2_type,
        $admin3_qid, $admin3_label, $admin3_type,
        $island_label, $island_admin_type
    ) = @$csv_record;

    my @admin_qids   = ($admin0_qid  , $admin1_qid  , $admin2_qid  , $admin3_qid  );
    my @admin_labels = ($admin0_label, $admin1_label, $admin2_label, $admin3_label);
    my @admin_types  = ($admin0_type , $admin1_type , $admin2_type , $admin3_type );

    foreach (0..3) {
        next if not exists ADDRESS_LABEL_REPLACEMENT->{$admin_qids[$_]};
        $admin_labels[$_] = ADDRESS_LABEL_REPLACEMENT->{$admin_qids[$_]};
    }

    my $marker_data = $Data{$qid};

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
            $region_name = 'Bangsamoro' if $region_name eq 'Bangsamoro Autonomous Region';
            $region_name = 'Cordillera' if $region_name eq 'Cordillera Administrative Region';

            if (exists $marker_data->{region}) {
                # Assume that a marker can only have at most 2 regions
                $marker_data->{region} = [$marker_data->{region}, $region_name];
            }
            else {
                $marker_data->{region} = $region_name;
            }
        }
    }
    if ($country ne 'Philippines') {
        push @address_parts, $country;
        if (not OVERSEAS_MACRO_ADDRESS->{$qid}) {
            log_error($qid, "Overseas marker has no macro address");
            return;
        }
        $marker_data->{macroAddress} = OVERSEAS_MACRO_ADDRESS->{$qid};
        $marker_data->{region} = 'Overseas';
    }
    else {
        $marker_data->{macroAddress} = join ', ', @macro_address_parts;
    }
    my $full_address = join ', ', @address_parts;
    $full_address =~ s/(^|, )([^, ]*)(?:, \2)+(, |$)/$1$2$3/g;

    if (exists $marker_data->{address}) {
        warn "WARNING: [$qid] Multiple addresses";
        $marker_data->{address} .= " / $full_address" ;
    }
    else {
        $marker_data->{address} = $full_address;
    }

    $marker_data->{locDesc} = $directions if $directions;

    return;
}

# ===================================================================

sub get_title_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?markerLabel ?title ?titleLangCode ?targetLangQid ?subtitle ?noValue
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker p:P1476 ?titleStatement .
  OPTIONAL {
    ?titleStatement ps:P1476 ?title .
    BIND(LANG(?title) AS ?titleLangCode) .
    OPTIONAL {
      ?titleStatement pq:P518 ?targetLang .
      BIND(SUBSTR(STR(?targetLang), 32) AS ?targetLangQid) .
    }
    OPTIONAL { ?titleStatement pq:P1680 ?subtitle }
  }
  OPTIONAL {
    ?titleStatement a ?noValue .
    FILTER (?noValue = wdno:P1476)
    OPTIONAL {
      ?titleStatement pq:P518 ?targetLang .
      BIND(SUBSTR(STR(?targetLang), 32) AS ?targetLangQid) .
    }
    ?marker rdfs:label ?markerLabel .
    FILTER (LANG(?markerLabel) = "en")
  }
}
EOQ
}

# -------------------------------------------------------------------

sub process_title_data_csv_record {

    my $csv_record = shift;
    my (
        $qid, $label,
        $title, $title_lang_code, $target_lang_qid,
        $subtitle, $has_no_title
    ) = @$csv_record;

    my $marker_data = $Data{$qid};

    if ($title_lang_code and not exists VALID_LANGUAGES->{$title_lang_code}) {
        log_error($qid, "Unrecognized title language code ($title_lang_code)");
        return;
    }
    if ($target_lang_qid and not exists LANGUAGE_CODE->{$target_lang_qid}) {
        log_error($qid, "Unrecognized title language item ($target_lang_qid)");
        return;
    }
    if ($has_no_title) {
        if (
            exists $marker_data->{details} and
            scalar keys %{$marker_data->{details}} > 0 and
            not $target_lang_qid
        ) {
            log_error($qid, "Marker is stated as both having no title and having a title");
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
            log_error($qid, "Marker is stated as both having no title and having a title");
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

    return;
}

# -------------------------------------------------------------------

# Sanity-check number of languages and titles, and also generate name field
sub post_process_title_data {
    while (my ($qid, $marker_data) = each %Data) {

        next if $marker_data->{has_no_title};
        if (
            scalar keys %{$marker_data->{details}} > 1 and
            $marker_data->{num_plaques} > 1 and
            scalar keys %{$marker_data->{details}} != $marker_data->{num_plaques}
        ) {
            log_error($qid, "Number of languages does not match number of plaques (P1114)");
            next;
        }
        if (scalar keys %{$marker_data->{details}} == 0) {
            log_error($qid, "Marker has no title information (P1476)");
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
    return;
}

# ===================================================================

sub get_inscription_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?inscription ?langCode ?noValue
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker p:P1684 ?inscriptionStatement .
  OPTIONAL {
    ?inscriptionStatement ps:P1684 ?inscription .
    BIND(LANG(?inscription) AS ?langCode) .
  }
  OPTIONAL {
    ?inscriptionStatement a ?noValue .
    FILTER (?noValue = wdno:P1684)
  }
}
EOQ
}

# -------------------------------------------------------------------

sub process_inscription_data_csv_record {

    my $csv_record = shift;
    my ($qid, $inscription, $lang_code, $has_no_inscription) = @$csv_record;

    my $marker_data = $Data{$qid};

    if ($has_no_inscription) {
        if (exists $marker_data->{has_no_title}) {
            log_error($qid, "Marker has no title and inscription");
            return;
        }
        foreach my $l10n_detail (values %{$marker_data->{details}}) {
            delete $l10n_detail->{inscription};
        }
    }
    else {
        process_inscription($qid, $inscription, $lang_code);
    }

    return;
}

# ===================================================================

sub get_long_inscription_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?content WHERE {
  SERVICE wikibase:mwapi {
    bd:serviceParam wikibase:api "Generator";
                    wikibase:endpoint "www.wikidata.org";
                    mwapi:generator "revisions";
                    mwapi:prop "revisions";
                    mwapi:rvprop "content";
                    mwapi:rvslots "*";
                    mwapi:titles "<<titles>>" .
    ?title wikibase:apiOutput mwapi:title .
    ?rawContent wikibase:apiOutput "revisions/rev/slots/slot/text()" . #
  }
  BIND(SUBSTR(?title, 6) AS ?markerQid) .
  BIND(REPLACE(?rawContent, "\n", "") AS ?content) .
}
EOQ
}

# -------------------------------------------------------------------

sub get_long_inscription_titles {
    my @titles;
    while (my ($qid, $marker_data) = each %Data) {
        foreach my $l10n_detail (values %{$marker_data->{details}}) {
            if (exists $l10n_detail->{inscription} and $l10n_detail->{inscription} eq '') {
                push @titles, "Talk:$qid";
                last;
            }
        }
    }
    return(join '|', @titles);
}

# -------------------------------------------------------------------

sub process_long_inscription_data_csv_record {

    my $csv_record = shift;
    my ($qid, $talk_content) = @$csv_record;

    my $marker_data = $Data{$qid};

    return unless $talk_content;

    while ($talk_content =~ /\{\{\s*LongInscription(.+?)}}/sg) {
        my $template_text = $1;
        my ($lang_qid   ) = $template_text =~ /\|\s*langqid\s*=\s*(Q[0-9]+)/s;
        my ($inscription) = $template_text =~ /\|\s*inscription\s*=\s*(.+?)(?:\||$)/s;
        if (not exists LANGUAGE_CODE->{$lang_qid}) {
            log_error($qid, "Inscription is in an unrecognized language ($lang_qid)");
            return;
        }
        if (length $inscription <= WIKIDATA_MAX_STR_LENGTH) {
            warn "WARNING: [$qid] \"Long\" inscription is <= " . WIKIDATA_MAX_STR_LENGTH . " characters in length";
        }
        process_inscription($qid, $inscription, LANGUAGE_CODE->{$lang_qid});
    }

    return;
}

# ===================================================================

sub get_unveiling_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?date ?datePrecision ?langQid
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker p:P571 ?dateStatement .
  OPTIONAL {
    ?dateStatement pq:P518 ?lang .
    BIND(SUBSTR(STR(?lang), 32) AS ?langQid) .
  }
  FILTER NOT EXISTS { ?dateStatement pq:P582 ?endTime }
  ?dateStatement psv:P571 ?dateValue .
  ?dateValue wikibase:timeValue ?date ;
             wikibase:timePrecision ?datePrecision .
}
EOQ
}

# -------------------------------------------------------------------

sub process_unveiling_data_csv_record {

    my $csv_record = shift;
    my ($qid, $date, $precision, $lang_qid) = @$csv_record;

    my $marker_data = $Data{$qid};

    if ($precision < 9 or 11 < $precision) {
        log_error($qid, "Date (P571) has an unexpected precision");
    }
    if ($lang_qid) {
        if ($marker_data->{num_plaques} == 1) {
            log_error($qid, "Date (P571) has a language (P518) but there is only 1 plaque (P1114)");
            return;
        }
        if (not exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}) {
            log_error($qid, "Date (P571) targets an extra language (P518)");
            return;
        }
        if (exists $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}{date}) {
            log_error($qid, "Date (P571) has a duplicate language (P518)");
            return;
        }
        $marker_data->{details}{LANGUAGE_CODE->{$lang_qid}}{date} = substr($date, 0, $precision == 11 ? 10 : 4);
        $marker_data->{date} = JSON()->true;
    }
    else {
        if (exists $marker_data->{details}{date}) {
            log_error($qid, "There is more than 1 date (P571)");
            return;
        }
        $marker_data->{date} = substr($date, 0, $precision == 11 ? 10 : 4);
    }

    return;
}

# ===================================================================

sub get_photo_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?photoFilename ?langQid ?ordinal ?vicinityPhotoFilename
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker p:P18 ?imageStatement .
  FILTER NOT EXISTS { ?imageStatement pq:P582 ?endTime }
  OPTIONAL {
    ?imageStatement ps:P18 ?photo .
    BIND(SUBSTR(STR(?photo), 52) AS ?photoFilename) .
    OPTIONAL {
      ?imageStatement pq:P518 ?lang .
      BIND(SUBSTR(STR(?lang), 32) AS ?langQid) .
    }
    OPTIONAL { ?imageStatement pq:P1545 ?ordinal }
    FILTER NOT EXISTS { ?imageStatement pq:P3831 wd:Q16968816 }
  }
  OPTIONAL {
    ?imageStatement ps:P18 ?photo .
    BIND(SUBSTR(STR(?photo), 52) AS ?vicinityPhotoFilename) .
    FILTER EXISTS { ?imageStatement pq:P3831 wd:Q16968816 }
  }
}
EOQ
}

# -------------------------------------------------------------------

sub process_photo_data_csv_record {

    my $csv_record = shift;
    my ($qid, $photo_filename, $lang_qid, $ordinal, $loc_photo_filename) = @$csv_record;

    $photo_filename     = decode('UTF-8', uri_unescape($photo_filename    ));
    $loc_photo_filename = decode('UTF-8', uri_unescape($loc_photo_filename));

    my $marker_data = $Data{$qid};

    if ($photo_filename) {
        my $photo_record = {
            file   => $photo_filename,
            credit => undef,
        };
        if ($marker_data->{num_plaques} == 1) {
            if (exists $marker_data->{photo}) {
                log_error($qid, "Multiple photos (P18) but there is only 1 plaque (P1114)");
                return;
            }
            $marker_data->{photo} = $photo_record;
        }
        else {
            if (not $lang_qid and not $ordinal) {
                log_error($qid, "Missing language (P518) or ordinal (P1545) for marker with multiple plaques (P1114)");
                return;
            }
            if ($lang_qid) {
                if (not exists LANGUAGE_CODE->{$lang_qid}) {
                    log_error($qid, "Photo is in an unrecognized language ($lang_qid) (P518)");
                    return;
                }
                my $lang_code = LANGUAGE_CODE->{$lang_qid};
                if (not exists $marker_data->{details}{$lang_code}) {
                    log_error($qid, "Photo is in an extra language ($lang_code) (P518)");
                    return;
                }
                if (exists $marker_data->{details}{$lang_code}{photo}) {
                    log_error($qid, "Duplicate photo language ($lang_code) (P518)");
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
            log_error($qid, "Multiple vicinity photos (P18 P3831 wd:Q16968816)");
            return;
        }
        $marker_data->{locPhoto} = {
            file   => $loc_photo_filename,
            credit => undef,
        };
    }

    return;
}

# ===================================================================

sub get_photo_metadata_sparql_query {
    return << 'EOQ';
SELECT ?filename ?width ?height ?author ?attrRequired ?license WHERE {
  SERVICE wikibase:mwapi {
    bd:serviceParam wikibase:api "Generator";
                    wikibase:endpoint "commons.wikimedia.org";
                    mwapi:generator "revisions";
                    mwapi:prop "imageinfo";
                    mwapi:iiprop "extmetadata|size";
                    mwapi:titles "<<titles>>" .
    ?title wikibase:apiOutput mwapi:title .
    ?width        wikibase:apiOutput "imageinfo/ii/@width"  .
    ?height       wikibase:apiOutput "imageinfo/ii/@height" .
    ?author       wikibase:apiOutput "imageinfo/ii/extmetadata/Artist/@value" .
    ?attrRequired wikibase:apiOutput "imageinfo/ii/extmetadata/AttributionRequired/@value" .
    ?license      wikibase:apiOutput "imageinfo/ii/extmetadata/LicenseShortName/@value" .
  }
  BIND(SUBSTR(?title, 6) AS ?filename) .
}
EOQ
}

# -------------------------------------------------------------------

sub get_photo_metadata_titles {

    my @titles;
    while (my ($qid, $marker_data) = each %Data) {

        # Get metadata for the marker's photo(s)
        if ($marker_data->{num_plaques} == 1) {
            if ($marker_data->{photo}) {
                my $filename = $marker_data->{photo}{file};
                $Photo_Metadata{$filename} = $marker_data->{photo};
                push @titles, "File:$filename";
            }
        }
        elsif ($marker_data->{photo}) {
            foreach my $idx (1..scalar @{$marker_data->{photo}}) {
                if ($marker_data->{photo}[$idx]) {
                    my $filename = $marker_data->{photo}[$idx]{file};
                    $Photo_Metadata{$filename} = $marker_data->{photo}[$idx];
                    push @titles, "File:$filename";
                }
            }
        }
        else {
            foreach my $lang_code (keys %{$marker_data->{details}}) {
                if ($marker_data->{details}{$lang_code}{photo}) {
                    my $filename = $marker_data->{details}{$lang_code}{photo}{file};
                    $Photo_Metadata{$filename} = $marker_data->{details}{$lang_code}{photo};
                    push @titles, "File:$filename";
                }
            }
        }

        # Get metadata for the marker vicinity photo
        if ($marker_data->{locPhoto}) {
            my $filename = $marker_data->{locPhoto}{file};
            if (exists $Photo_Metadata{$filename}) {
                # Reuse vicinity photo metadata for reused vicinity photos
                $marker_data->{locPhoto} = $Photo_Metadata{$filename};
            }
            else {
                $Photo_Metadata{$filename} = $marker_data->{locPhoto};
                push @titles, "File:$filename";
            }
        }
    }

    # Group into chunks of 20 files to avoid MediaWiki API 'URI too long' error
    foreach (@titles) { s/"/\\"/g }
    my @chunks;
    push @chunks, [splice @titles, 0, 40] while @titles;
    foreach (@chunks) { $_ = join '|', @$_ }
    return \@chunks;
}

# -------------------------------------------------------------------

sub process_photo_metadata_csv_record {

    my $csv_record = shift;
    my ($filename, $width, $height, $author, $needs_attr, $license) = @$csv_record;

    say "WARN: [$filename] Photo author is missing" if (not $author);
    $author =~ s/<[^>]+>//g;
    $author =~ s/\n//g;

    if ($needs_attr eq 'false') {
        $license = '';
    }
    else {
        $license =~ s/ / /g;  # non-breaking space
        $license =~ s/-/‑/g;  # Non-breaking hyphen
        $license = " {$license}";
    }

    my $credit = "$author$license";

    $Photo_Metadata{$filename}{width } = $width  + 0;
    $Photo_Metadata{$filename}{height} = $height + 0;
    $Photo_Metadata{$filename}{credit} = $credit;

    return;
}

# ===================================================================

sub get_commemorates_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?commemoratesLabel ?articleTitle
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?marker wdt:P547 ?commemorates .
  ?commemorates rdfs:label ?commemoratesLabel .
  FILTER (LANG(?commemoratesLabel) = "en")
  ?articleUrl schema:about ?commemorates ;
              schema:isPartOf <https://en.wikipedia.org/> .
  BIND(SUBSTR(STR(?articleUrl), 31) as ?articleTitle) .
}
EOQ
}

# -------------------------------------------------------------------

sub process_commemorates_data_csv_record {

    my $csv_record = shift;
    my ($qid, $label, $title) = @$csv_record;

    $title = decode('UTF-8', uri_unescape($title)) =~ s/_/ /gr;

    my $marker_data = $Data{$qid};
    $marker_data->{wikipedia} //= {};
    $marker_data->{wikipedia}{$label} = $label eq $title ? JSON()->true : $title;

    return;
}

# ===================================================================

sub get_category_data_sparql_query {
    return << 'EOQ';
SELECT ?markerQid ?category
WHERE {
  <<sparql_values>>
  BIND(SUBSTR(STR(?marker), 32) AS ?markerQid) .
  ?categoryUrl schema:about ?marker ;
               schema:isPartOf <https://commons.wikimedia.org/> .
  BIND(SUBSTR(STR(?categoryUrl), 45) as ?category) .
}
EOQ
}

# -------------------------------------------------------------------

sub process_category_data_csv_record {
    my $csv_record = shift;
    my ($qid, $category) = @$csv_record;
    $Data{$qid}{commons} = $category;
    return;
}

# ===================================================================
# UTILITY SUBROUTINES/FUNCTIONS
# ===================================================================

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

# -------------------------------------------------------------------

sub query_wikimedia_api {

    my $api_url     = shift;
    my $extra_props = shift;

    # Query API
    my $ua = LWP::UserAgent->new;
    $ua->default_header(Accept => 'application/json');
    my %post_body = (
        format => 'json',
        action => 'query',
        %$extra_props,
    );
    my $response = $ua->post($api_url, \%post_body);

    # Parse and return API response (return undef if data is not found)
    my $response_raw = decode_json($response->decoded_content);
    my $page_id = +(keys %{$response_raw->{query}{pages}})[0];
    return $page_id == -1 ? undef : $response_raw->{query}{pages}{$page_id};
}

# -------------------------------------------------------------------

sub process_inscription {

    my $qid         = shift;
    my $inscription = shift;
    my $lang_code   = shift;

    # HTML-format the inscription
    $inscription =~ s/ +/ /g;
    $inscription =~ s/^\s+//g;
    $inscription =~ s/\s+$//g;
    $inscription =~ s{<br */?>\s*<br */?>}{</p><p>}g;
    $inscription = "<p>$inscription</p>";

    my $marker_data = $Data{$qid};

    if ($lang_code and not exists VALID_LANGUAGES->{$lang_code}) {
        log_error($qid, "Inscription is in an unrecognized language ($lang_code)");
    }
    if (
        not exists $marker_data->{has_no_title} and
        $lang_code and
        not exists $marker_data->{details}{$lang_code}
    ) {
        log_error($qid, "Inscription is in an extra language ($lang_code)");
    }
    if (not exists $marker_data->{details}) {
        if (not exists $marker_data->{has_no_title}) {
            log_error($qid, "Weird data inconsistency error");
        }
        $marker_data->{details} = {};
    }
    if (not exists $marker_data->{details}{$lang_code}) {
        if (not exists $marker_data->{has_no_title}) {
            log_error($qid, "Weird data inconsistency error");
        }
        $marker_data->{details}{$lang_code} = { inscription => $inscription }
    }
    else {
        $marker_data->{details}{$lang_code}{inscription} = $inscription;
    }

    return;
}

# -------------------------------------------------------------------

sub log_error {
    my $qid       = shift;
    my $error_msg = shift;
    push @Error_Msgs, "ERROR: [$qid] $error_msg";
    return;
}
