#!/usr/bin/perl

use strict;
use Net::OAuth::Client;
use Data::Dumper;
use XML::Simple;
use Getopt::Long;
use Date::Parse;

my $debug=0;
my $tokenFile="$ENV{'HOME'}/.TourneyManagerTokens";
my $showHelp=0;
my $tourneyListFile;
my $dataDir="./XML";
my %ownerFor;
my %nameForTeam;
my $force=0; #force new downloads
my %teamNumber; # teamNumber{managerName}{teamName}

my @rankedTeams;
my @winnerTableInfo;

my $xml = new XML::Simple;

GetOptions('debug'=>\$debug, 'force'=>\$force, 'tourneylistfile=s'=>\$tourneyListFile, 'help'=>\$showHelp);
&showUsage() if ($showHelp||!length($tourneyListFile));

if (! -d $dataDir) {
    mkdir $dataDir, 0777 or die "Error: can't create '$dataDir'\n";
}

my %tokens = &checkForTokens();
my $app=Net::OAuthStuff->new(%tokens);
my $CHPPurl="http://chpp.hattrick.org/chppxml.ashx";
my @tournaments;
my @editions;
open(T, $tourneyListFile) or &showUsage("Error: can't open tourney list file '$tourneyListFile'");
while(<T>) {
    s/#.*//;
    s/^\s*(.*)\s*$/\1/;
    next if (/^\s*$/);
    if ($_ !~ /^(\d+)\s*(\d+)*\s*$/) {
        die "Error: syntax error on line $. of $tourneyListFile\n$_\n";
    }
    else {
        push @tournaments, $1;
        push @editions, $2;
    }
}
close(T);

print "Have " . ($#tournaments+1) . " tournaments to process...\n";

&getAccessToken($app); # will read from config file or prompt if not found

my @allRankings;

# OK, now we can get the matches for each team
my $division = 0;
for (my $tcnt=0; $tcnt<=$#tournaments; $tcnt++) {
    my @semifinalWinners;
    my @semifinalLosers;
    my $winner;
    $division++;
    print "Processing results for division '$division' [tournament $tournaments[$tcnt]]...\n";
    my $tournament = $tournaments[$tcnt];
    my $edition = $editions[$tcnt] || 1 ;
    my $baseName = "T" . $tournament . (defined($edition)?"E$edition":"");

    if ((! -f "$dataDir/$baseName.xml")||$force) {
        my $tourneyInfoXML=&fetchXMLinfo({file=>'tournamentdetails', version=>'1.0', tournamentID=>"$tournament"}, "$dataDir/$baseName.xml");
    }
    else {
        print "Already have result for tournament '$tournament', skipping...\n" if ($debug);
    }

    # now get the tournament fixture info
    if ((! -f "$dataDir/$baseName" . "-fixtures.xml")||$force) {
        my $fixtureXML = &fetchXMLinfo({file=>'tournamentfixtures', version=>'1.0', tournamentId=>"$tournament"}, "$dataDir/$baseName" . "-fixtures.xml");
    }
    else {
        print "Already have tournament fixtures for tournament '$tournament'\n" if ($debug);
    }

    # need the tournamentleaguetables XML in case of a tie
    if ((! -f "$dataDir/$baseName" . "-standings.xml")||$force) {
        my $standingsXML = &fetchXMLinfo({file=>'tournamentleaguetables', version=>'1.0', tournamentId => "$tournament"}, "$dataDir/$baseName" . "-standings.xml");
    }
    else {
        print "Already have stadings for tournament '$tournament', skipping...\n" if ($debug);
    }


    # now parse the fixture XML to figure out final rankings
    my %rankingInfo; # place, points, gf and ga for each teamid

    # read fixtures file to get playoff results...
    my $xmldata = $xml->XMLin("$dataDir/$baseName" . "-fixtures.xml");
    #print Dumper($xmldata);
    foreach my $match (@{$xmldata->{'Matches'}->{'Match'}}) {
        if ($match->{'MatchType'} eq '50') {
            print "Skipping group round match '" . $match->{'MatchId'} . "'...\n";
            next;
        }
        print "Checking playoff match '" . $match->{'MatchId'} . "'...\n";
        die "Something unexpected happened, got match type of " . $match->{"MatchType"} . "\n" if ($match->{'MatchType'} ne '51');
        my $homeID = $match->{'HomeTeamId'};
        my $awayID = $match->{'AwayTeamId'};
        #die "Error: home goals = away goals in match $match->{'MatchId'}\n" . Dumper($xmldata) . "\n" if ($match->{'HomeGoals'} eq $match->{'AwayGoals'});
        $winner = ($match->{'HomeGoals'} > $match->{'AwayGoals'})?$homeID:$awayID;
        my $loser  = ($match->{'HomeGoals'} < $match->{'AwayGoals'})?$homeID:$awayID;
        print "HOME:$homeID (" . $match->{'HomeGoals'} . ") AWAY:$awayID (" . $match->{'AwayGoals'} . ")\n";
        if (grep /^$winner$/, @semifinalWinners) {
            print "Tourney winner $winner!\n";
        }
        else {
            print "$winner wins semifinal match\n";
            push @semifinalWinners, $winner;
        }

        if (! grep /^$loser$/, @semifinalWinners) {
            push @semifinalLosers, $loser;
        }

    }

    # now need to parse XML files
    print "Group results for '$baseName':\n";
    my $xmldata = $xml->XMLin("$dataDir/$baseName" . "-standings.xml");
    #print Dumper($xmldata);

    my $group=1;
    my @thirdPlaceTeams;
    my @fourthPlaceTeams;
    foreach my $group (@ { $xmldata->{'TournamentLeagueTables'}->{'TournamentLeagueTable'}}) {
        my $groupPos = 1;
        foreach my $team (@{$group->{'Teams'}->{'Team'}}) {
            my $teamID = $team->{'TeamID'};
            $nameForTeam{$teamID} = $team->{'TeamName'};
            push @thirdPlaceTeams, $teamID if ($team->{'Position'} eq '3');
            push @fourthPlaceTeams, $teamID if ($team->{'Position'} eq '4');
            $rankingInfo{$teamID}{'PLACE'}=$team->{'Position'};
            $rankingInfo{$teamID}{'POINTS'} = $team->{'Points'};
            $rankingInfo{$teamID}{'GF'} = $team->{'GoalsFor'};
            $rankingInfo{$teamID}{'GA'} = $team->{'GoalsAgainst'};
            # make sure we have team info...
            my $ownerName = &getOwner($teamID);
            print "$groupPos ID: $teamID [owner: '$ownerName'] Name: " . $team->{'TeamName'} . " P:$rankingInfo{$team}{'POINTS'} GF:$rankingInfo{$team}{'GF'} GA:$rankingInfo{$team}{'GA'}\n";
            $groupPos++;
        }
        $group++;
    }

    # OK, now that we have all the results, rank the teams;
    my @theseRanks=();
    # of course, the winner is the winner
    push @theseRanks, $winner;
    print "WINNER: $theseRanks[0] ($winner)\n";
    # the other semifinal winner is second place
    foreach my $team (@semifinalWinners) {
        next if (grep /^$team$/, @theseRanks);
        push @theseRanks, $team;
    }
    print "Top two: " . join(", ", @theseRanks) . "\n";
    # next come the 1/2 place teams who are not yet ranked
    print "Ranking semifinal losers: " . join(', ', @semifinalLosers) . "\n";
    print "SFL0 '$semifinalLosers[0]' P: $rankingInfo{$semifinalLosers[0]}{'POINTS'}\n";
    push @theseRanks, &rank(@semifinalLosers, \%rankingInfo);
    print "Ranking third place teams: " . join(", ", @thirdPlaceTeams) . "\n";
    push @theseRanks, &rank(@thirdPlaceTeams, \%rankingInfo);
    print "Ranking fourth place teams: " . join(", ", @fourthPlaceTeams) . "\n";
    push @theseRanks, &rank(@fourthPlaceTeams, \%rankingInfo);

    print "Final tournament ranking:\n\t" . join("\n\t", @theseRanks) . "\n";
    print "WINNER of DIVISION $division: $theseRanks[0] ($ownerFor{$theseRanks[0]})\n";

    push @winnerTableInfo, $division, $theseRanks[0], $ownerFor{$theseRanks[0]}, $tournaments[$tcnt];

    print "\nnow adjusting overall rankings... start:" . join(",", @theseRanks) . "\n";
    if ($#allRankings>0) {
        print "We have previous results, need to pull the upper-level demotees down...\n";
        my $demotee2=pop @allRankings;
        my $demotee1=pop @allRankings;
        print "Demotees of prev tournament are $demotee1 and $demotee2...\n";

        my $curDemotee2=pop @theseRanks;
        my $curDemotee1=pop @theseRanks;
        print "Demotees of cur tournament are $curDemotee1 and $curDemotee2\n";

        @theseRanks=(@theseRanks[0..5], $demotee1, $demotee2, $curDemotee1, $curDemotee2);
    }
    push @allRankings, @theseRanks;

    print "ADJUSTED RANKING FOR NEXT TOURNAMENT:\n";
    foreach my $team (@allRankings) {
        print "\t$team [$ownerFor{$team}]\n";
    }
    #print "\t" . join("\n\t", @allRankings) . "\n";

    print "\nSignup Table:\n";
    print "[table]\n";
    print "[tr][th]div[/th][th]link[/th][th]waitlist[/th][/tr]\n";
    my $div=1;
    for (my $cnt=0;$cnt<=$#allRankings;$cnt+=8) {
        print "[tr][td]" . $div . "[/td][td] -- [/td][td]";
        for (my $c=0;$c<8;$c++) {
            my $who=$ownerFor{$allRankings[$cnt+$c]};
            my $whichTeam = $teamNumber{$who}{$allRankings[$cnt+$c]};
            my $addedText = "";
            $addedText = " (2nd team)" if ($whichTeam==2);
            die "Team number '$whichTeam' not supported.\n" if ($whichTeam>2);
            print "$who$addedText, ";
        }
        print "[/td][/tr]\n";
        $div++;
    }
    print "[/table]\n\n";
}

print "Results table:\n";
print "[table]\n[tr][th colspan=4 align=center]Season ??? results[/th][/tr]\n";
print "[tr][th]Division[/th][th]Champion[/th][th]Manager[/th][th]Link[/th][/tr]\n";
while($#winnerTableInfo>=0) {
    my $division = shift @winnerTableInfo;
    my $team = shift @winnerTableInfo;
    my $owner = shift @winnerTableInfo;
    my $tournament = shift @winnerTableInfo;
    print "[tr][td]" . $division . "[/td][td]" . $nameForTeam{$team} . "[/td][td]" . $owner . "[/td][td][tournamentid=" . $tournament . "][/td][/tr]\n";
}
print "[/table]\n";

sub rank {
    my $teamid1=shift;
    my $teamid2=shift;
    my $rankInfo=shift;

    my $points1 = $rankInfo->{$teamid1}{'POINTS'};
    my $points2 = $rankInfo->{$teamid2}{'POINTS'};
    my $gf1      = $rankInfo->{$teamid1}{'GF'};
    my $gf2     = $rankInfo->{$teamid2}{'GF'};
    my $ga1    = $rankInfo->{$teamid1}{'GA'};
    my $ga2   = $rankInfo->{$teamid2}{'GA'};

    if ($points1>$points2) {
        return ($teamid1, $teamid2);
    }
    elsif ($points2>$points1) {
        return ($teamid2,$teamid1);
    }
    elsif ( ($gf1-$ga1) > ($gf2-$ga2)) {
        return ($teamid1,$teamid2);
    }
    elsif ( ($gf2-$ga2) > ($gf1-$ga1)) {
        return ($teamid2,$teamid1);
    }
    elsif ($gf1 > $gf2) {
        return ($teamid1,$teamid2);
    }
    elsif ($gf2 > $gf1) {
        return ($teamid2,$teamid1);
    }
    else {
        die "Error: can't rank team '$teamid1' (P:$points1 GF:$gf1 GA:$ga1) and team '$teamid2' (P:$points2 GF:$gf2 GA:$ga2)\nHave info for:" . join("\t\n", keys %$rankInfo) . "\n";
    }
}

sub getOwner {
    my $teamID = shift;
    return $ownerFor{$teamID} if (defined($ownerFor{$teamID}));
    my $teamInfoFile = $dataDir . "/" . "Team" . $teamID . ".xml";
    if ((! -f "$teamInfoFile")||$force) {
        my $teamXML = &fetchXMLinfo({file=>'teamdetails', version=>'3.1', teamID=>"$teamID"}, $teamInfoFile);
        print "Wrote team info file for team $teamID...\n";
    }
    else { 
        print "Already have team info for team '$teamID', not fetching XML...\n" if ($debug);
    }
    my $teamInfo = $xml->XMLin($teamInfoFile);
    #print Dumper($teamInfo);
    $ownerFor{$teamID}=$teamInfo->{'User'}->{'Loginname'};

    # now, determine if this is the first or second team
    my $managerID = $teamInfo->{'User'}->{'UserID'};
    my $managerInfoFile = $dataDir . "/" . "Manager" . $managerID . ".xml";
    my $managerInfoXML = &fetchXMLinfo({file=>'managercompendium', version=>'1.0', userId=>$managerID}, $managerInfoFile) if ((! -f $managerInfoFile)||$force);

    my $managerInfo = $xml->XMLin($managerInfoFile);
    my $tcount = 1;
    my $teamInfo = $managerInfo->{'Manager'}->{'Teams'}->{'Team'};
    print Dumper($teamInfo);
    if (ref($managerInfo->{'Manager'}->{'Teams'}->{'Team'}) eq 'ARRAY') {
        for my $one (@{$managerInfo->{'Manager'}->{'Teams'}->{'Team'}}) {
            print $tcount . ":$one:" . $one->{'TeamName'} . "\n";
            if ($one->{'TeamId'} == $teamID) {
                $teamNumber{$ownerFor{$teamID}}{$teamID} = $tcount;
            }
            $tcount++;
        }
    }
    else {
        $teamNumber{$ownerFor{$teamID}}{$teamID} = 1; 
    }
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
