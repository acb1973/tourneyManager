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
my $dataDir="./XML";

GetOptions('debug'=>\$debug, 'tourneylistfile=s'=>\$tourneyListFile, 'help'=>\$showHelp);
&showUsage() if ($showHelp||!length($tourneyListFile));

if (! -d $dataDir) {
    mkdir $dataDir, 0777 or die "Error: can't create '$dataDir'\n";
}

my %tokens = &checkForTokens();
my $app=Net::OAuthStuff->new(%tokens);
my $CHPPurl="http://chpp.hattrick.org/chppxml.ashx";
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
    if (! -f "$dataDir/$tournament.xml") {
        my $tourneyInfoXML=&fetchXMLinfo({file=>'tournamentdetails', version=>'1.0', tournamentID=>"$tournament"}, "$dataDir/$tournament.xml");
    }
    else {
        print "Already have result for tournament '$tournament', skipping...\n" if ($debug);
    }

    # now get the tournament fixture info
    if (! -f "$dataDir/$tournament" . "-fixtures.xml") {
        my $fixtureXML = &fetchXMLinfo({file=>'tournamentfixtures', version=>'1.0', tournamentId=>"$tournament"}, "$dataDir/$tournament" . "-fixtures.xml");
    }
    else {
        print "Already have tournament fixtures for tournament '$tournament'\n" if ($debug);
    }


    # and the standings info
}

sub fetchXMLinfo {
    my $apiInfo=shift;
    my $outfile=shift;
    my $xmloutput;

    my $result = $app->view_restricted_resource($CHPPurl,$apiInfo);
    if (($result->is_success)&&($result->content!~/<Error>/)) {
        $xmloutput=$result->content;
        open(OUT, "> $outfile") or die "Error: can't write '$outfile'\n";
        print OUT $xmloutput;
        close(OUT);
        print "Wrote '$outfile'...\n";
    }
    else {
        print STDERR "Error fetching XML data, got:\n";
        print STDERR Dumper($result);
        die "\n";
    }
    return $xmloutput;
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
