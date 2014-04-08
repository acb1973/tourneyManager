#!/usr/bin/perl

use strict;
use Net::OAuth::Client;
use Data::Dumper;
use XML::Hash;
use Getopt::Long;
use Date::Parse;

my $debug=0;
my $tokenFile="$ENV{'HOME'}/.TourneyManagerTokens";
my $showHelp=0;
my $tourneyListFile;

# database
# -tournament
#    -division
#    -season
#    -groups
#    
#    - teams involved



GetOptions('debug'=>\$debug, 'tourneylistfile=s'=>\$tourneyListFile, 'help'=>\$showHelp);
&showUsage() if ($showHelp||!length($tourneyListFile));

my %tokens = &checkForTokens();
my $app=Net::OAuthStuff->new(%tokens);
my @tournaments;
open(T, $tourneyListFile) or &showUsage("Error: can't open tourney list file '$tourneyListFile'");
while(<T>) {
    s/#.*//;
    s/^\s*(.*)\s*$/\1/;
    next if (/^\s*$/);
    if ($_ !~ /^(\d+)$/) {
        die "Error: syntax error on line $. of $tourneyListFile\n$_\n";
    }
    else {
        push @tournaments, $1;
    }
}
close(T);

print "Have " . ($#tournaments+1) . " tournaments to process...\n";

&getAccessToken($app); # will read from config file or prompt if not found

# OK, now we can get the matches for each team
foreach my $tournament (@tournaments) {
    if (-f "$tournament.xml") {
        print "Already have result for tournament '$tournament', skipping...\n" if ($debug);
        next;
    }
    my $url="http://chpp.hattrick.org/chppxml.ashx";
    print "Fetching tourney info from URL: '$url'\n" if ($debug);
    my $result = $app->view_restricted_resource($url, {file=>'tournamentdetails', version=>'1.0', tournamentID=>"$tournament"});
    if (($result->is_success)&&($result->content!~/<Error>/)) {
        my $xmloutput = $result->content;
        open(OUT, "> $tournament.xml");
        print OUT $xmloutput;
        close OUT;
        print "Wrote output for Tournament '$tournament' to '$tournament.xml'\n";

        my $xmlConverter=XML::Hash->new();
        my $dataHash = $xmlConverter->fromXMLStringtoHash($xmloutput);
        print Dumper($dataHash) if ($debug);


    }
    else {
        print STDERR "Error with data for tournament '$tournament', got:\n";
        print STDERR Dumper($result);
        die "\n";
    }

    # now get the tournament fixture info
    $result = $app->view_restricted_resource($url, {file=>'tournamentfixtures', version=>'1.0', tournamentId=>"$tournament"});
    if (($result->is_success)&&($result->content!~/<Error>/)) {
        my $xmloutput = $result->content;
        open(OUT, "> $tournament" . "-fixtures.xml");
        print OUT $xmloutput;
        close(OUT);
        print "Wrote fixture info for tournament '$tournament' to '$tournament" . "-fixtures.xml\n";
    }
    else {
        print STDERR "Error with fixture data for tournament '$tournament', got:\n";
        print SDTERR Dumper($result);
        die "\n";
    }
}

sub checkForTokens {
    my %retVal;

    open(TOK, $tokenFile);
    while(<TOK>) {
        chomp;
        my @fields=split /=/;
        $retVal{$fields[0]}=$fields[1];
        print "SETTING '$fields[0]' to '$fields[1]' from config file '$tokenFile'\n" if ($debug);
    }
    $retVal{'consumer_key'}='BZvO3wUHtoOuL8giwkUFgD';
    $retVal{'consumer_secret'}='DotghbG22wBC2JoLTOcfZR9lATByTSzHG2Hcx2YYtqI';
    return %retVal;
}

sub getAccessToken {
    my $app=shift;

    return if ($app->authorized);

    if ($debug) {
        print "We're not authorized, current app tokens are:\n";
        foreach my $key (keys %{$app->{tokens}}) {
            print "$key: $app->{tokens}->{$key}\n";
        }

    }

    print "Please go to " . $app->get_authorization_url(callback=>'oob') . "\n";
    print "Type in the code you get after authenticating here: \n";
    my $code = <STDIN>;
    chomp $code;
    print "code from website is '$code'\n" if ($debug);
    my ($access_token, $access_token_secret) = $app->request_access_token(verifier => $code);

    print "Got access_token=$access_token\naccess_token_secret=$access_token_secret\n" if ($debug);
    open(TOK, "> $tokenFile");
    print TOK "access_token=$access_token\naccess_token_secret=$access_token_secret\n";
    close(TOK);

}

sub showUsage {
    my $msg=shift;
    print STDERR "$msg\n" if (length($msg));
    die "Usage: $0 -tourneylistfile=<tourney list file>\n";
}

package Net::OAuthStuff;

use strict;
use Net::OAuth::Simple;
use base qw(Net::OAuth::Simple);

sub new {
    my $class  = shift;
    my %tokens = @_;
    return $class->SUPER::new( tokens => \%tokens, 
        protocol_version => '1.0a',
        urls   => {
        authorization_url => 'https://chpp.hattrick.org/oauth/authorize.aspx',
        request_token_url => 'https://chpp.hattrick.org/oauth/request_token.ashx',
        access_token_url  => 'https://chpp.hattrick.org/oauth/access_token.ashx',
        oauth_callback => 'oob'
    });
}

sub view_restricted_resource {
    my $self=shift;
    my $url=shift;
    my $paramsRef=shift;
    if ($debug) {
    print "PARAMS:\n";
        foreach my $key (keys %$paramsRef) {
            print "$key = $paramsRef->{$key}\n";
        }
    }
    print "URL:$url\n" if ($debug);
    return $self->make_restricted_request($url, 'GET', %$paramsRef);
}

sub  update_restricted_resource {
    my $self=shift;
    my $url=shift;
    my $extra_params_ref=shift;
    return $self->make_restricted_request($url, 'POST', %$extra_params_ref);
}

1;
