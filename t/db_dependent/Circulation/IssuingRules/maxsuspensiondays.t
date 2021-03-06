use Modern::Perl;
use Test::More tests => 2;

use MARC::Record;
use MARC::Field;
use Test::MockModule;
use C4::Context;

use C4::Biblio qw( AddBiblio );
use C4::Circulation qw( AddIssue AddReturn );
use C4::Items qw( AddItem );
use C4::Members qw( AddMember GetMember );
use Koha::Database;
use Koha::DateUtils;
use Koha::Patron::Debarments qw( GetDebarments DelDebarment );

use t::lib::TestBuilder;

my $schema = Koha::Database->schema;
$schema->storage->txn_begin;
my $builder = t::lib::TestBuilder->new;
my $dbh = C4::Context->dbh;
$dbh->{RaiseError} = 1;

my $library = $builder->build({
    source => 'Branch',
});

my $branchcode = $library->{branchcode};
local $SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /redefined/ };
my $userenv->{branch} = $branchcode;
*C4::Context::userenv = \&Mock_userenv;

my $circulation_module = Test::MockModule->new('C4::Circulation');

# Test without maxsuspensiondays set
$circulation_module->mock('GetIssuingRule', sub {
        return {
            firstremind => 0,
            finedays => 2,
            lengthunit => 'days',
        }
});

my $borrowernumber = AddMember(
    firstname =>  'my firstname',
    surname => 'my surname',
    categorycode => 'S',
    branchcode => $branchcode,
);
my $borrower = GetMember( borrowernumber => $borrowernumber );

my $record = MARC::Record->new();
$record->append_fields(
    MARC::Field->new('100', ' ', ' ', a => 'My author'),
    MARC::Field->new('245', ' ', ' ', a => 'My title'),
);

my $barcode = 'bc_maxsuspensiondays';
my ($biblionumber, $biblioitemnumber) = AddBiblio($record, '');
my (undef, undef, $itemnumber) = AddItem({
        homebranch => $branchcode,
        holdingbranch => $branchcode,
        barcode => $barcode,
    } , $biblionumber);

# clear any holidays to avoid throwing off the suspension day
# calculations
$dbh->do('DELETE FROM special_holidays');
$dbh->do('DELETE FROM repeatable_holidays');

my $daysago20 = dt_from_string->add_duration(DateTime::Duration->new(days => -20));
my $daysafter40 = dt_from_string->add_duration(DateTime::Duration->new(days => 40));

AddIssue( $borrower, $barcode, $daysago20 );
AddReturn( $barcode, $branchcode );
my $debarments = GetDebarments({borrowernumber => $borrower->{borrowernumber}});
is(
    $debarments->[0]->{expiration},
    output_pref({ dt => $daysafter40, dateformat => 'iso', dateonly => 1 }),
    'calculate suspension with no maximum set'
);
DelDebarment( $debarments->[0]->{borrower_debarment_id} );

# Test with maxsuspensiondays = 10 days
$circulation_module->mock('GetIssuingRule', sub {
        return {
            firstremind => 0,
            finedays => 2,
            maxsuspensiondays => 10,
            lengthunit => 'days',
        }
});
my $daysafter10 = dt_from_string->add_duration(DateTime::Duration->new(days => 10));
AddIssue( $borrower, $barcode, $daysago20 );
AddReturn( $barcode, $branchcode );
$debarments = GetDebarments({borrowernumber => $borrower->{borrowernumber}});
is(
    $debarments->[0]->{expiration},
    output_pref({ dt => $daysafter10, dateformat => 'iso', dateonly => 1 }),
    'calculate suspension with a maximum set'
);
DelDebarment( $debarments->[0]->{borrower_debarment_id} );


# C4::Context->userenv
sub Mock_userenv {
    return $userenv;
}
