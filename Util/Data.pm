# Data management.
# $Id$

package Util::Data;

use warnings;
use strict;

use Exporter;
use Carp qw(croak);
use POE;
use Storable;
use Util::Conf;

use vars  qw(@ISA @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(
  store_paste fetch_paste delete_paste list_paste_ids
  delete_paste_by_id fetch_paste_channel clear_channel_ignores
  set_ignore clear_ignore get_ignores is_ignored channels add_channel
  remove_channel clear_channels
);

sub PASTE_TIME    () { 0 }
sub PASTE_SUMMARY () { 1 }
sub PASTE_ID      () { 2 }
sub PASTE_NETWORK () { 3 }
sub PASTE_CHANNEL () { 4 }
sub PASTE_HOST    () { 5 }

my $id_sequence = 0;
my %paste_cache;
my %ignores; # $ignores{$ircnet}{lc $channel} = [ mask, mask, ... ];
my %channels;

# return a list of all paste ids

sub list_paste_ids {
  return keys %paste_cache;
}

# remove pastes that are too old (if applicable)
sub check_paste_count {
  my @names = get_names_by_type('pastes');
  return unless @names;
  my %conf = get_items_by_name($names[0]);
  return unless %conf && $conf{'count'};
  return if (scalar keys %paste_cache < $conf{'count'});
  my $oldest = (
    sort {
      $paste_cache{$a}->[PASTE_TIME] > $paste_cache{$b}->[PASTE_TIME]
    } keys %paste_cache
  )[0];
  delete_paste_by_id($oldest);
}

# Save paste, returning an ID.

sub store_paste {
  my ($id, $summary, $paste, $ircnet, $channel, $ipaddress) = @_;
  check_paste_count();

  my $new_id = ++$id_sequence;
  $paste_cache{$new_id} = [
    time(),       # PASTE_TIME
    $summary,     # PASTE_SUMMARY
    $id,          # PASTE_ID
    $ircnet,      # PASTE_NETWORK
    lc($channel), # PASTE_CHANNEL
    $ipaddress,   # PASTE_HOST
  ];

  store \%paste_cache, 'pastestore/Index';

  open BODY, ">", "pastestore/$new_id"
    or warn "I cannot store paste $new_id: $!";
  binmode(BODY);
  print BODY $paste;
  close BODY;

  return $new_id;
}

# Fetch paste by ID.

sub fetch_paste {
  my $id = shift;
  my $paste = $paste_cache{$id};
  return(undef, undef, undef) unless defined $paste;

  unless(open BODY, "<", "pastestore/$id") {
    warn "Error opening paste $id: $!";
    return(undef, undef, undef);
  }
  local $/ = undef;

  return(
    $paste->[PASTE_ID],
    $paste->[PASTE_SUMMARY],
    <BODY>
  );
}

# Fetch the channel a paste was meant for.

sub fetch_paste_channel {
  my $id = shift;
  return $paste_cache{$id}->[PASTE_CHANNEL];
}

sub delete_paste_by_id {
  my $id = shift;
  delete $paste_cache{$id};
  unlink "pastestore/$id"
    or warn "Problem removing paste $id: $!";
  store \%paste_cache, 'pastestore/Index';
}

# Delete a possibly sensitive or offensive paste.

sub delete_paste {
  my ($ircnet, $channel, $id, $bywho) = @_;

  if (
    $paste_cache{$id}[PASTE_NETWORK] eq $ircnet &&
    $paste_cache{$id}[PASTE_CHANNEL] eq lc $channel
  ) {
    # place the blame where it belongs
    unless (open BODY, ">", "pastestore/$id") {
      warn "Error deleting body for paste $id: $!";
      return;
    }
    print BODY "Deleted by $bywho";
  }
  else {
    return;
  }
}

# manage channel/IRC network based ignores of http requestors

sub _convert_mask {
  my $mask = shift;

  $mask =~ s/\./\\./g;
  $mask =~ s/\*/\\d+/g;

  $mask;
}

sub is_ignored {
  my ($ircnet, $channel, $host) = @_;

  $ignores{$ircnet}{lc $channel} && @{$ignores{$ircnet}{lc $channel}}
    or return;

  for my $mask (@{$ignores{$ircnet}{lc $channel}}) {
    $host =~ /^$mask$/ and return 1;
  }

  return;
}

sub set_ignore {
  my ($ircnet, $channel, $mask) = @_;

  $mask = _convert_mask($mask);

  # remove any existing mask - so it's not fast
  @{$ignores{$ircnet}{lc $channel}} =
    grep $_ ne $mask, @{$ignores{$ircnet}{lc $channel}};
  push @{$ignores{$ircnet}{lc $channel}}, $mask;
  store \%ignores, "ignorelist";
}

sub clear_ignore {
  my ($ircnet, $channel, $mask) = @_;

  $mask = _convert_mask($mask);

  @{$ignores{$ircnet}{lc $channel}} =
    grep $_ ne $mask, @{$ignores{$ircnet}{lc $channel}};
  store \%ignores, "ignorelist";
}

sub get_ignores {
  my ($ircnet, $channel) = @_;

  $ignores{$ircnet}{lc $channel} or return;

  my @masks = @{$ignores{$ircnet}{lc $channel}};

  for (@masks) {
    s/\\d\+/*/g;
    s/\\././g;
  }

  @masks;
}

sub clear_channel_ignores {
  my ($ircnet, $channel) = @_;

  $ignores{$ircnet}{lc $channel} = [];
  store \%ignores, "ignorelist";
}

# Channels we're on

sub channels {
  return sort keys %channels;
}

sub clear_channels {
  %channels = ();
  return if keys %channels;  # Should never happen
  return 1;
}

sub add_channel {
  my ($channel) = @_;
  $channel = lc($channel);
  $channels{$channel} = 1;
}

sub remove_channel {
  my ($channel) = @_;
  $channel = lc($channel);
  delete $channels{$channel};  # returns automatically
}

# Init stuff

mkdir "pastestore" unless -d "pastestore";
if (-e "pastestore/Index") {
  %paste_cache = %{retrieve 'pastestore/Index'};
  $id_sequence = (sort keys %paste_cache)[-1];
}
if (-e "ignorelist") {
  %ignores = %{retrieve 'ignorelist'};
}

my @pastes = get_names_by_type('pastes');
if (@pastes) {
  my %conf = get_items_by_name($pastes[0]);
  if ($conf{'check'} && $conf{'expire'}) {
    POE::Session->new(
      _start => sub { $_[KERNEL]->delay( ticks => $conf{'check'} ); },
      ticks => sub {
        for (keys %paste_cache) {
          next unless (time - $paste_cache{$_}->[PASTE_TIME]) > $conf{'expire'};
          delete_paste_by_id($_);
        }
        $_[KERNEL]->delay( ticks => $conf{'check'} );
      },
    );
  }
}

1;
