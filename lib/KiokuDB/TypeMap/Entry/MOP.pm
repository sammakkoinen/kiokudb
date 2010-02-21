#!/usr/bin/perl

package KiokuDB::TypeMap::Entry::MOP;
use Moose;

use Scalar::Util qw(refaddr);
use Carp qw(croak);

use KiokuDB::Thunk;

no warnings 'recursion';

sub does_role {
    my ($meta, $role) = @_;
    return unless my $does = $meta->can('does_role');
    return $meta->$does($role);
}

use namespace::clean -except => 'meta';

with (
    'KiokuDB::TypeMap::Entry::Std',
    'KiokuDB::TypeMap::Entry::Std::Expand' => {
        alias => { compile_expand => 'compile_expand_body' },
    }
);

has [qw(class_version_table version_table)] => (
    isa => "HashRef",
    is  => "ro",
    default => sub { return {} },
);

has write_upgrades => (
    isa => "Bool",
    is  => "ro",
    default => 0,
);

# FIXME collapser and expaner should both be methods in Class::MOP::Class,
# apart from the visit call

sub compile_collapse_body {
    my ( $self, $class, @args ) = @_;

    my $meta = Class::MOP::get_metaclass_by_name($class);

    my @attrs = grep {
        !does_role($_->meta, 'KiokuDB::Meta::Attribute::DoNotSerialize')
            and
        !does_role($_->meta, 'MooseX::Storage::Meta::Attribute::Trait::DoNotSerialize')
    } $meta->get_all_attributes;

    my %lazy;
    foreach my $attr ( @attrs ) {
        $lazy{$attr->name}  = does_role($attr->meta, "KiokuDB::Meta::Attribute::Lazy");
    }

    my $meta_instance = $meta->get_meta_instance;

    my %attrs;

    if ( $meta->is_anon_class ) {

        # FIXME ancestral roles all the way up to first non anon ancestor,
        # at least check for additional attributes or other metadata which we
        # should probably error on anything we can't store

        # theoretically this can do multiple inheritence too

        my $ancestor = $meta;
        my @anon;

        search: {
            push @anon, $ancestor;

            my @super = $ancestor->superclasses;

            if ( @super == 1 ) {
                $ancestor = Class::MOP::get_metaclass_by_name($super[0]);
                if ( $ancestor->is_anon_class ) {
                    redo search;
                }
            } elsif ( @super > 1 ) {
                croak "Cannot resolve anonymous class with multiple inheritence: " . $meta->name;
            } else {
                croak "no super, ancestor: $ancestor (" . $ancestor->name . ")";
            }
        }

        my $class_meta = $ancestor->name;

        foreach my $anon ( reverse @anon ) {
            $class_meta = {
                roles => [
                    map { $_->name } map {
                        $_->isa("Moose::Meta::Role::Composite")
                            ? @{$_->get_roles}
                            : $_
                    } @{ $anon->roles }
                ],
                superclasses => [ $class_meta ],
            };
        }

        if ( $class_meta->{superclasses}[0] eq $ancestor->name ) {
            # no need for redundancy, expansion will provide this as the default
            delete $class_meta->{superclasses};
        }

        %attrs = (
            class => $ancestor->name,
            class_meta => $class_meta,
        );
    }

    my $immutable  = does_role($meta, "KiokuDB::Role::Immutable");
    my $content_id = does_role($meta, "KiokuDB::Role::ID::Content");

    my @extra_args;

    if ( defined( my $version = $meta->version ) ) {
        push @extra_args, class_version => $version;
    }

    return (
        sub {
            my ( $self, %args ) = @_;

            my $object = $args{object};

            if ( $immutable ) {
                # FIXME this doesn't handle unset_root
                if ( my $prev = $self->live_objects->object_to_entry($object) ) {
                    return $self->make_skip_entry( %args, prev => $prev );
                } elsif ( $content_id ) {
                    if ( ($self->backend->exists($args{id}))[0] ) { # exists works in list context
                        return $self->make_skip_entry(%args);
                    }
                }
            }

            my %collapsed;

            attr: foreach my $attr ( @attrs ) {
                my $name = $attr->name;
                if ( $attr->has_value($object) ) {
                    if ( $lazy{$name} ) {
                        my $value = $meta_instance->Class::MOP::Instance::get_slot_value($object, $name); # FIXME fix KiokuDB::Meta::Instance to allow fetching thunk

                        if ( ref $value eq 'KiokuDB::Thunk' ) {
                            $collapsed{$name} = $value->collapsed;
                            next attr;
                        }
                    }

                    my $value = $attr->get_raw_value($object);
                    $collapsed{$name} = ref($value) ? $self->visit($value) : $value;
                }
            }

            return $self->make_entry(
                @extra_args,
                %args,
                data => \%collapsed,
            );
        },
        %attrs,
    );
}

sub compile_expand {
    my ( $self, $class, $resolver, @args ) = @_;

    my $meta = Class::MOP::get_metaclass_by_name($class);

    my $typemap_entry = $self;

    my $anon = $meta->is_anon_class;

    my $inner = $self->compile_expand_body($class, $resolver, @args);

    my $version = $meta->version;

    return sub {
        my ( $linker, $entry, @args ) = @_;

        if ( $entry->has_class_meta and !$anon ) {
            # the entry is for an anonymous subclass of this class, we need to
            # compile that entry and short circuit to it. if $anon is true then
            # we're already compiled, and the class_meta is already handled
            my $anon_meta = $self->reconstruct_anon_class($entry);

            my $anon_class = $anon_meta->name;

            unless ( $resolver->resolved($anon_class) ) {
                $resolver->compile_entry($anon_class, $typemap_entry);
            }

            my $method = $resolver->expand_method($anon_class);
            return $linker->$method($entry, @args);
        }

        if ( $self->is_version_up_to_date($meta, $version, $entry->class_version) ) {
            $linker->$inner($entry, @args);
        } else {
            my $upgraded = $self->upgrade_entry( linker => $linker, meta => $meta, entry => $entry, expand_args => \@args);

            if ( $self->write_upgrades ) {
                croak "Upgraded entry can't be updated (mismatch in 'prev' chain)"
                    unless refaddr($entry) == refaddr($upgraded->root_prev);

                $linker->backend->insert($upgraded);
            }

            $linker->$inner($upgraded, @args);
        }
    }
}

sub is_version_up_to_date {
    my ( $self, $meta, $version, $entry_version ) = @_;

    # no clever stuff, only if they are the same string they are the same version

    no warnings 'uninitialized'; # undef $VERSION is allowed
    return 1 if $version eq $entry_version;

    # check the version table for equivalent versions (recursively)
    # ref handlers are upgrade hooks
    foreach my $handler ( $self->find_version_handlers($meta, $entry_version) ) {
        return $self->is_version_up_to_date( $meta, $version, $handler ) if not ref $handler;
    }

    return;
}

sub find_version_handlers {
    my ( $self, $meta, $version ) = @_;

    no warnings 'uninitialized'; # undef $VERSION is allowed

    grep { defined } map { $_->{$version} } $self->class_version_table->{$meta->name}, $self->version_table;
}


sub upgrade_entry {
    my ( $self, %args ) = @_;
    $self->upgrade_entry_from_version( %args, from_version => $args{entry}->class_version );
}

sub upgrade_entry_from_version {
    my ( $self, %args ) = @_;

    my ( $meta, $from_version, $entry ) = @args{qw(meta from_version entry)};

    no warnings 'uninitialized'; # undef $VERSION is allowed

    foreach my $handler ( $self->find_version_handlers($meta, $from_version) ) {
        if ( ref $handler ) {
            # apply handler
            my $converted = $self->$handler(%args);

            if ( $self->is_version_up_to_date( $meta, $meta->version, $converted->class_version ) ) {
                return $converted;
            } else {
                # more error context
                return try {
                    $self->upgrade_entry_from_version(%args, entry => $converted, from_version => $converted->class_version);
                } catch {
                    croak "$_\n... when upgrading from $from_version";
                };
            }
        } else {
            # nonref is equivalent version, recursively search for handlers for that version
            return $self->upgrade_entry_from_version( %args, from_version => $handler );
        }
    }

    croak "No handler found for " . $meta->name . " version $from_version" . ( $entry->class_version ne $from_version ? "(entry version is " . $entry->class_version . ")" : "" );
}

sub compile_create {
    my ( $self, $class ) = @_;

    my $meta = Class::MOP::get_metaclass_by_name($class);

    my $meta_instance = $meta->get_meta_instance;

    return sub { $meta_instance->create_instance() };
}

sub compile_clear {
    my ( $self, $class ) = @_;

    return sub {
        my ( $linker, $obj ) = @_;
        %$obj = (); # FIXME
    }
}

sub compile_expand_data {
    my ( $self, $class, @args ) = @_;

    my $meta = Class::MOP::get_metaclass_by_name($class);

    my $meta_instance = $meta->get_meta_instance;

    my ( %attrs, %lazy );

    my @attrs = grep {
        !does_role($_->meta, 'KiokuDB::Meta::Attribute::DoNotSerialize')
            and
        !does_role($_->meta, 'MooseX::Storage::Meta::Attribute::Trait::DoNotSerialize')
    } $meta->get_all_attributes;

    foreach my $attr ( @attrs ) {
        $attrs{$attr->name} = $attr;
        $lazy{$attr->name}  = does_role($attr->meta, "KiokuDB::Meta::Attribute::Lazy");
    }

    return sub {
        my ( $linker, $instance, $entry, @args ) = @_;

        my $data = $entry->data;

        my @values;

        foreach my $name ( keys %$data ) {
            my $attr = $attrs{$name} or croak "Unknown attribute: $name";
            my $value = $data->{$name};

            if ( ref $value ) {
                if ( $lazy{$name} ) {
                    my $thunk = KiokuDB::Thunk->new( collapsed => $value, linker => $linker, attr => $attr );
                    $attr->set_raw_value($instance, $thunk);
                } else {
                    my @pair = ( $attr, undef );

                    $linker->inflate_data($value, \$pair[1]) if ref $value;
                    push @values, \@pair;
                }
            } else {
                $attr->set_raw_value($instance, $value);
            }
        }

        $linker->queue_finalizer(sub {
            foreach my $pair ( @values ) {
                my ( $attr, $value ) = @$pair;
                $attr->set_raw_value($instance, $value);
                $attr->_weaken_value($instance) if $attr->is_weak_ref;
            }
        });

        return $instance;
    }
}

sub reconstruct_anon_class {
    my ( $self, $entry ) = @_;

    $self->inflate_class_meta(
        superclasses => [ $entry->class ],
        %{ $entry->class_meta },
    );
}

sub inflate_class_meta {
    my ( $self, %meta ) = @_;

    foreach my $super ( @{ $meta{superclasses} } ) {
        $super = $self->inflate_class_meta(%$super)->name if ref $super;
    }

    # FIXME should probably get_meta_by_name($entry->class)
    Moose::Meta::Class->create_anon_class(
        cache => 1,
        %meta,
    );
}

sub compile_id {
    my ( $self, $class ) = @_;

    if ( does_role(Class::MOP::get_metaclass_by_name($class), "KiokuDB::Role::ID") ) {
        return sub {
            my ( $self, $object ) = @_;
            return $object->kiokudb_object_id;
        }
    } else {
        return "generate_uuid";
    }
}

sub should_compile_intrinsic {
    my ( $self, $class, @args ) = @_;

    my $meta = Class::MOP::get_metaclass_by_name($class);

    if ( $self->has_intrinsic ) {
        return $self->intrinsic;
    } elsif ( does_role($meta, "KiokuDB::Role::Intrinsic") ) {
        return 1;
    } else {
        return 0;
    }
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

KiokuDB::TypeMap::Entry::MOP - A L<KiokuDB::TypeMap> entry for objects with a
metaclass.

=head1 SYNOPSIS

    KiokuDB::TypeMap->new(
        entries => {
            'My::Class' => KiokuDB::TypeMap::Entry::MOP->new(
                intrinsic => 1,
            ),
        },
    );

=head1 DESCRIPTION

This typemap entry handles collapsing and expanding of L<Moose> based objects.

It supports anonymous classes with runtime roles, the L<KiokuDB::Role::ID> role.

Code for immutable classes is cached and performs several orders of magnitude
better, so make use of L<Moose::Meta::Class/make_immutable>.

=head1 ATTRIBUTES

=over 4

=item intrinsic

If true the object will be collapsed as part of its parent, without an ID.

=back
