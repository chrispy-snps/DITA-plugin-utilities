#!/usr/bin/perl
# make_dita_grammar.pl - make DITA RelaxNG grammar plugin modules from high-level descriptions
#
# Prerequisites on linux:
#
#  sudo apt update
#  sudo apt install cpanminus
#  sudo cpanm install XML::Twig Acme::Tools

# TO-DO
# * create RelaxNG schema for the XML input files
# * rewrite all the grammar modification stuff
# * support selective attribute addition to content models
# * after all modifications, if <nesting> is defined for a topic, warn if <${topic}-info-types> is not found in the content models
# * all the TO-DO markers throughout the script

use strict;
use warnings;

use Getopt::Long 'HelpMessage';
use XML::Twig;
use Acme::Tools;
use File::Path qw(make_path remove_tree);
use File::Find;
use File::Basename;
use File::Spec;
use Cwd qw(realpath);
use Carp qw(croak);

my $ditaot = '';  # you can put your own default here, if you want
my $verbose = 0;
GetOptions(
 'ditaot=s'     => \$ditaot,
 'verbose'      => \$verbose,
 'help'         => sub { HelpMessage(0) }
) or HelpMessage(1);
my $input_file = shift or HelpMessage(1);

# read in user's high-level grammar description file
my $plugin = my_twig->new(elt_class => 'my_elt')->parsefile($input_file)->root;
print "Processing '$input_file'...\n";

# make output plugin directory
my $plugin_directory = $plugin->att('directory');
my $rng_directory = File::Spec->catdir($plugin_directory, 'rng');
my $template_directory = File::Spec->catdir($plugin_directory, 'templates');
remove_tree($rng_directory, $template_directory);
make_path($plugin_directory, $rng_directory, $template_directory);



########################################
# READ ALL GRAMMAR FILES
#
# read in existing grammar files, in no particular order
#
# the only prerequisite here is that @#pfile is defined on the grammar, so
# we know its physical file and can process includes of it accordingly
my @all_grammars = ();  # unsorted
my %base_domain_of = ();
my %base_element_of = ();
my %defaultvalue_of = ();
my %modinclude_for_domain = ();
my %domain_for_pfile = ();
my %elements_defined_in_domain = ();
my %elements_included_by_domain = ();
my %domains_that_define_element = ();
my %domaincontribution_for_domain = ();
my %idnames_for_domain = (glossgroup => {'glossgroup' => 1}, glossentry => {'glossentry' => 1}, reference => {'reference' => 1}, 'strictTaskbody-c' => {'task' => 1});  # these are missing in the DITA grammar files (sort of a bug)
my %idnamespaces_for_domain = ();
my %domains_provided_by_domain = ();  # domains that are implicitly included, e.g. constraints that provide their base modules
my %domains_referenced_by_domain = ();  # domains that are referenced, e.g. specializations of base domains
my %grammars_by_domain = ();
my %pfile_for_urn = ();

sub process_grammar {
 my $grammar = shift;
 my $rngmod = $grammar->first_descendant('rngMod') or return;  # only process modules, as we build things from them
 return if $rngmod->text eq 'urn:oasis:names:tc:dita:rng:glossaryMod.rng';  # skip redirect-only module
 $pfile_for_urn{$rngmod->text} = $grammar->att('#pfile');  # this makes urn-based includes work

 # analyze each tag's specialization ancestry from @a:defaultValue of @class attributes
 my $domain_name;
 foreach my $defaultvalue (map {$_->att('a:defaultValue')} ($grammar->get_xpath('.//attribute[@name="class" and @a:defaultValue]'))) {
  my @from_tag_classes = ($defaultvalue =~ m!\S+\/\S+!g);
  my ($base_domain, $base_tag) = domain_and_tag($from_tag_classes[0]);
  my ($this_domain, $this_tag) = domain_and_tag($from_tag_classes[-1]);
  if (!$domain_name) {$domain_name = $this_domain;} else {croak "Conflicting domain names $domain_name and $this_domain" if $domain_name ne $this_domain;}
  $base_domain_of{$this_domain}->{$this_tag} = $base_domain;
  $base_element_of{$this_domain}->{$this_tag} = $base_tag;
  $defaultvalue_of{$this_domain}->{$this_tag} = $defaultvalue;
  $domains_that_define_element{$this_tag}->{$this_domain} = 1;
  $elements_defined_in_domain{$this_domain}->{$this_tag} = 1;
  $elements_included_by_domain{$this_domain}->{$this_domain}->{$this_tag} = 1;
 }

 # check if we're defining a domain (base modules don't, they just provide common elements)
 if ($grammar->get_xpath('.//moduleType[string()!="base"]')) {
  # derive domain information for this file (not as easy as you'd think!)
  #  (base topic/map elements don't have a domain contribution)
  # we prefer the domain from the last entry in @a:defaultvalue...
  my $dc = $grammar->first_descendant('domainsContribution');
  if (!$domain_name) {$domain_name = ($dc->text =~ m!\s(\S+)\)$!g)[0];}  # ...but for attributes, we resort to the attribute name instead
  $modinclude_for_domain{$domain_name} = ($grammar->att('base_output_filename') or $rngmod->text);  # use local filename if we made this module
  $domain_for_pfile{$grammar->att('#pfile')} = $domain_name;
  my $dctxt = ($dc ? $dc->text : '');
  $domaincontribution_for_domain{$domain_name} = $dctxt if $dc;
  @{$domains_referenced_by_domain{$domain_name}} = minus([(split /\s+/, ($dctxt =~ s!.*\((.*)\).*!$1!r))], ['props', 'base']);  # these are satisfied intrinsically
  @{$domains_provided_by_domain{$domain_name}} = ($domain_name);  # start with ourself, we'll add included domains later
 }
 push @{$grammars_by_domain{($domain_name or 'topic')}}, $grammar;  # this is a list because multiple common element modules contribute to 'topic'
 $grammar->set_att('#domain', ($domain_name or ''));  # having an empty value helps us with sorting later on

 # remember explicitly defined ID-requiring elements
 foreach my $ide ($grammar->get_xpath('.//define[@name="idElements" and @combine="choice"]')) {
  $idnames_for_domain{$domain_name}->{($ide->first_child('ref')->rngname =~ m!^(\w+)\.element$!g)[0]} = 1;
 }

 # identify foreign namespaces
 my %known_namespaces = map {$_ => 1} qw(http://relaxng.org/ns/structure/1.0 http://relaxng.org/ns/compatibility/annotations/1.0 http://dita.oasis-open.org/architecture/2005/ http://purl.oclc.org/dsdl/schematron http://www.w3.org/1999/xlink);
 foreach my $nsatt (grep /^xmlns:/, (keys %{$grammar->atts})) {
  my $ns = $grammar->att($nsatt);
  push @{$idnamespaces_for_domain{$domain_name}}, $ns if defined($domain_name) && !defined($known_namespaces{$ns});
 }

 # print table information
 my $dn = ($domain_name or '-');
 my $mt = $grammar->first_descendant('moduleType'); if ($mt) {$mt = $mt->text;} else {$mt = '-';}
 my $f = basename($grammar->att('#pfile') or $grammar->att('base_output_filename'));
 my $i = join(',', (map {basename($_->att('href'))} $grammar->descendants('include')));
 printf "  %-20s %-35s %-50s %-50s\n", $mt, $dn, $f, $i if $verbose;

 push @all_grammars, $grammar;
}

print " Reading existing grammar files...\n";
{
 my @rng_dirs = ();
 if ($ditaot = ($ditaot or get_ditaot_dir())) {
  my $ditaotfull = File::Spec->rel2abs($ditaot);
  croak "Can't find '${ditaot}'\n" if !-e $ditaotfull;
  croak "'$ditaot' is not a directory\n" if !-d $ditaotfull;
  my $rngdir = File::Spec->catdir($ditaotfull, "plugins/org.oasis-open.dita.v1_3/rng");
  croak "Can't find '${rngdir}'\n" if !-d $rngdir;
  push @rng_dirs, realpath($rngdir);
 }
 push @rng_dirs, map {realpath($_->text)} $plugin->children('existing_files');
 foreach my $dir (uniq @rng_dirs) {
  print "  Reading files in '$dir'...\n";
  foreach my $file (get_rng_files($dir)) {
   my $this_grammar = my_twig->new(elt_class => 'my_elt')->parsefile($file)->root->cut;
   $this_grammar->set_att('#pfile', adjust_local_path($file, '.'));  # @pfile contains the full unambiguous physical filesystem path to the module
   process_grammar($this_grammar);
  }
 }
}

########################################
# REORDER GRAMMARS
#
# put the grammars in order (we can't do this until everything is read in)
my @all_grammars_up;
my @all_grammars_dn;
my @sorted_domains_up;
my @sorted_domains_dn;
sub reorder_grammars {
 # build a reference of which files include other files
 my %pfiles_included_from_pfile = ();
 foreach my $i (map {$_->descendants('include')} @all_grammars) {
  push @{$pfiles_included_from_pfile{$i->inherit_att('#pfile', 'grammar')}}, included_pfile($i);
 }

 # assign successive level values to "leaf" grammars that don't include any still-unprocessed grammars
 $_->del_att('#inclevel') for @all_grammars;
 my $level = 1;
 while (my @remaining_grammars = grep {!defined($_->att('#inclevel'))} @all_grammars) {
  my %remaining_pfiles = map {$_->att('#pfile') => 1} (@remaining_grammars);
  foreach my $grammar (@remaining_grammars) {
   $grammar->set_att('#inclevel', $level) if (!grep {defined($remaining_pfiles{$_})} @{$pfiles_included_from_pfile{$grammar->att('#pfile')}});
  }
  $level++;
 }

 # *_up has including domains followed by included domains (e.g., concept, topic)
 # *_dn has included domains followed by including domains (e.g., topic, concept)
 @all_grammars_up = sort {$a->att('#inclevel') <=> $b->att('#inclevel') or $a->att('#domain') cmp $b->att('#domain')} @all_grammars;
 @all_grammars_dn = sort {$b->att('#inclevel') <=> $a->att('#inclevel') or $a->att('#domain') cmp $b->att('#domain')} @all_grammars;
 @sorted_domains_up = grep {$_ ne ''} map {$_->att('#domain')} @all_grammars_up;
 @sorted_domains_dn = grep {$_ ne ''} map {$_->att('#domain')} @all_grammars_dn;
}
reorder_grammars();

sub process_ordered_grammar {
 my $grammar = shift;
 my $this_domain = $grammar->att('#domain') or return;
 foreach my $include ($grammar->descendants('include')) {  # propagate <notAllowed> up through includes
  if (my $included_domain = $domain_for_pfile{included_pfile($include)}) {
   push @{$domains_provided_by_domain{$this_domain}}, @{$domains_provided_by_domain{$included_domain}};
   my %disallowed_elements = map {$_ => 1} (map {($_->parent->rngname) =~ s!\.element$!!r} ($include->get_xpath('.//define[@name=~/.*\.element$/]/notAllowed')));
   foreach my $domain_in_include (@{$domains_provided_by_domain{$included_domain}}) {
    $elements_included_by_domain{$this_domain}->{$domain_in_include}->{$_} = 1 for grep {!defined($disallowed_elements{$_})} (keys %{$elements_included_by_domain{$included_domain}->{$domain_in_include}});  # only copy allowed elements
   }
  }
 }
 @{$domains_provided_by_domain{$this_domain}} = intersect($domains_provided_by_domain{$this_domain}, \@sorted_domains_dn);  # reorder
}
process_ordered_grammar($_) for @all_grammars_up;

########################################
# WRITE NEW GRAMMARS

# define the plugin catalog to accumulate
my $catalogtwig = my_twig->new(elt_class => 'my_elt');
my $catalog = $catalogtwig->parse('<?xml version="1.0" encoding="UTF-8"?><catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog"/>')->root;

# define the XML header for DITA vocabulary files
my $grammar_template = <<'EOS';
<?xml version="1.0" encoding="UTF-8"?>
<?xml-model href="urn:oasis:names:tc:dita:rng:vocabularyModuleDesc.rng"
  schematypens="http://relaxng.org/ns/structure/1.0"?>
<grammar xmlns:a="http://relaxng.org/ns/compatibility/annotations/1.0"
  xmlns:dita="http://dita.oasis-open.org/architecture/2005/"
  xmlns="http://relaxng.org/ns/structure/1.0"
  xmlns:sch="http://purl.oclc.org/dsdl/schematron">
  <moduleDesc xmlns="http://dita.oasis-open.org/architecture/2005/">
    <moduleTitle>REPLACEME</moduleTitle>
    <headerComment>REPLACEME</headerComment>
    <moduleMetadata>
      <moduleType>REPLACEME</moduleType>
      <moduleShortName>REPLACEME</moduleShortName>
      <modulePublicIds>REPLACEME</modulePublicIds>
    </moduleMetadata>
  </moduleDesc>
</grammar>
EOS

my $uri_prefix = $plugin->att('uri_prefix');
foreach my $new_file ($plugin->children) {
 next if $new_file->matches('existing_files');

 # get filename information for this module
 my $new_domain = $new_file->att('domain') if $new_file->matches('elementdomain|attributedomain|topic|map|constraint');
 my %domain_suffix = (elementdomain => '-d', attributedomain => '', topic => '-t', map => '-t', constraint => '-c');
 if (my $suffix_should_be = $domain_suffix{$new_file->tag}) {
  if ($new_domain !~ m!$suffix_should_be$!) { croak "Suffix for domain name '$new_domain' should be '$suffix_should_be'"; }
 }
 my %file_suffix = (elementdomain => 'Domain', attributedomain => 'Att', topic => 'TopicMod', map => 'MapMod', constraint => 'ConstraintMod');
 my $base_output_filename = ($new_file->att('filename') or (${new_domain} =~ s!-\w$!!r)[0].$file_suffix{$new_file->tag}.'.rng');
 croak "Cannot have directory name in '$base_output_filename'" if $base_output_filename =~ m!\/!;
 my $full_output_filename = File::Spec->catdir($rng_directory, $base_output_filename);
 print " Creating '$base_output_filename' (".$new_file->tag.")...\n";

 my $urn = "${uri_prefix}:${base_output_filename}";

 # create a twig for our new grammar and fill in basic information
 # (common to all grammar types)
 my $newtwig = my_twig->new(elt_class => 'my_elt');
 my $new_grammar = $newtwig->parse($grammar_template)->root;
 my $root_element = $new_file->first_child_text('root_element') if $new_file->matches('topicshell|mapshell');
 my $module_title = ($new_file->first_child_text('title') or $new_file->tag." Module for ".($new_domain ? "${new_domain} Domain" : "${root_element}"));
 $new_grammar->first_descendant('moduleTitle')->set_text($module_title);
 $new_grammar->first_descendant('moduleType')->set_text($new_file->tag);
 $new_grammar->first_descendant('headerComment')->set_text($new_file->first_child_text('header') or "Header Comment for $module_title");
 $new_grammar->first_descendant('moduleShortName')->set_text($new_domain or $module_title);

 my $info_types_patterns = insert_div($new_grammar, 'INFO TYPES PATTERNS') if $new_file->matches('topic');
 my $domain_extension_patterns = insert_div($new_grammar, 'DOMAIN EXTENSION PATTERNS') if $new_file->matches('elementdomain');
 my $element_type_name_patterns = insert_div($new_grammar, 'ELEMENT TYPE NAME PATTERNS') if $new_file->matches('elementdomain|topic|map');
 my $element_type_declarations = insert_div($new_grammar, 'ELEMENT TYPE DECLARATIONS') if $new_file->matches('elementdomain|topic|map');
 my $specialization_attribute_declarations = insert_div($new_grammar, 'SPECIALIZATION ATTRIBUTE DECLARATIONS') if $new_file->matches('elementdomain|topic|map');
 my $root_element_declaration = insert_div($new_grammar, 'ROOT ELEMENT DECLARATION') if $new_file->matches('topicshell|mapshell');
 my $domains_attribute = insert_div($new_grammar, 'DOMAINS ATTRIBUTE') if $new_file->matches('topicshell|mapshell');
 my $content_constraint_integration = insert_div($new_grammar, 'CONTENT CONSTRAINT INTEGRATION') if $new_file->matches('topicshell|mapshell');
 my $module_inclusions = insert_div($new_grammar, 'MODULE INCLUSIONS') if $new_file->matches('topicshell|mapshell');
 my $id_element_overrides = insert_div($new_grammar, 'ID-DEFINING-ELEMENT OVERRIDES') if $new_file->matches('topicshell|mapshell');
 my $content_model_overrides = insert_div($new_grammar, 'CONTENT MODEL OVERRIDES') if $new_file->matches('constraint');
 my $extra_content_models = insert_div($new_grammar, 'EXTRA CONTENT MODELS') if $new_file->matches('elementdomain|topic|map|constraint');

 if ($new_file->matches('attributedomain')) {
  my $specialization = $new_file->first_child('specialize');
  my ($new_atts, $from_att) = ($specialization->att('attribute'), $specialization->att('from'));
  croak "Attributes must be specialized from props or base, not '$from_att'" if !($from_att =~ m!^(base|props)$!);
  foreach my $new_att (split /\s+/, $new_atts) {
   my $attribute = insert_xml($new_grammar, "<define name='${new_att}-d-attribute'/>", '<optional/>', "<attribute name='$new_att'/>");
   $attribute->set_content(make_content_model($specialization->att('model'), 1)) if $specialization->att('model');
   insert_xml($new_grammar, "<define name='${from_att}-attribute-extensions' combine='interleave'/>", "<ref name='${new_att}-d-attribute'/>") unless ($specialization->att('allow_by_default') or 'true') eq 'false';
   insert_xml($new_grammar->first_descendant('moduleMetadata'), "<domainsContribution>a(${from_att} ${new_att})</domainsContribution>");
  }
 }


 # get domains needed by specializations, constraints, and document type shells
 my @available_domains = () if $new_file->matches('elementdomain|topic|map|constraint|topicshell|mapshell');
 if ($new_file->matches('elementdomain|topic|map|topicshell|mapshell|constraint')) {
  push @available_domains, (split /\s+/, ($new_file->first_child_text('include_domains')));
  if (my @notfound = grep {!defined($grammars_by_domain{$_})} @available_domains) {croak "Can't find domains '@notfound'";}
  foreach my $tag (grep {$_} $root_element, map {split /\s+/} ($new_file->children_atts('specialize', 'from'), $new_file->children_atts('constrain', 'elements'))) {
   push @available_domains, domain(add_domain($tag, @sorted_domains_up)) if !intersect([keys %{$domains_that_define_element{$tag}}], \@available_domains);
  }
  while (1) {
   my %missing_domains = ();
   foreach my $wd (@available_domains) {
    foreach my $rd (@{$domains_referenced_by_domain{$wd}}) {
     next if ($new_file->matches('mapshell') && $rd eq 'topic');  # for maps, elements with 'topic/' root come from commonElementsMod.rng, referenced by mapMod.rng instead of topicMod.rng
     push @{$missing_domains{$rd}}, $wd if (!intersect([$rd], \@available_domains));
    }
   }
   my @rds = keys %missing_domains or last;
   print "  Information: Including domain '$_' in '$base_output_filename' (required by domain '@{$missing_domains{$_}}').\n" for @rds;
   push @available_domains, @rds;
  }
 }

 my @available_domains_up = intersect(\@available_domains, \@sorted_domains_up) if $new_file->matches('elementdomain|topic|map|constraint|topicshell|mapshell');
 my @available_domains_dn = intersect(\@available_domains, \@sorted_domains_dn) if $new_file->matches('elementdomain|topic|map|constraint|topicshell|mapshell');

 # determine which elements are disallowed in each domain
 my %disallowed_in_domain if $new_file->matches('topicshell|mapshell|constraint');
 if ($new_file->matches('topicshell|mapshell|constraint')) {
  foreach my $aord ($new_file->children('allow[@domain]|disallow')) {
   my @elements = (split /\s+/, $aord->att('elements'));
   if ($aord->matches('allow') && (my $domain = $aord->att('domain'))) {
    if (my @notfound = minus(\@elements, [keys %{$elements_defined_in_domain{$domain}}])) { croak "Elements not found in domain $domain: @notfound"; }
    $disallowed_in_domain{$domain}->{$_} = 1 for keys %{$elements_defined_in_domain{$domain}};
    delete($disallowed_in_domain{$domain}->{$_}) for @elements;
   } elsif ($aord->matches('disallow')) {
    $disallowed_in_domain{domain(add_domain($_, @available_domains))}->{$_} = 1 for @elements;
   }
  }
 }

 # include needed modules (and notAlloweds)
 my %include_for_domain = () if $new_file->matches('constraint');
 if ($new_file->matches('topicshell|mapshell|constraint')) {
  my @unsatisfied_domains = @available_domains_dn;
  while (my $domain = shift @unsatisfied_domains) {
   @unsatisfied_domains = minus(\@unsatisfied_domains, $domains_provided_by_domain{$domain});
   my $include;
   $include = insert_xml($domain =~ m!\-c$! ? $content_constraint_integration : $module_inclusions, "<include href='$modinclude_for_domain{$domain}'/>") if $new_file->matches('topicshell|mapshell');
   $include = insert_xml($content_model_overrides, "<include href='$modinclude_for_domain{$domain}'/>") if $new_file->matches('constraint');
   $include_for_domain{$_} = $include for @{$domains_provided_by_domain{$domain}};
   $include->insert_new_elt('first_child', '#COMMENT', "provided domains: ".join(' ', sort @{$domains_provided_by_domain{$domain}}));
   foreach my $this_domain (@{$domains_provided_by_domain{$domain}}) {
    print "  Information: Domain '$domain' provides domain '$this_domain' in '$base_output_filename'.\n" if $domain ne $this_domain;
    my ($allowed, $disallowed) = part {!defined($disallowed_in_domain{$this_domain}->{$_})} (sort keys %{$elements_included_by_domain{$domain}->{$this_domain}});
    insert_xml($include, "<define name='${_}.element'/>", '<notAllowed/>') for (@$disallowed);
    $include->insert_new_elt('last_child', '#COMMENT', "provided elements from '$this_domain': @$allowed") if @$allowed;
   }
  }
 }

# get all grammars in the scope of this new grammar, including itself
 my @grammars_in_scope = ((map {@{$grammars_by_domain{$_}}} @available_domains_up), $new_grammar) if $new_file->matches('elementdomain|topic|map|constraint|topicshell');

 
 # add docshell topic-info-types (defaults to a copy of the topic-info-types default in the topic's module)
 if ($new_file->matches('topicshell')) {
  my $root_element_domain = domain(add_domain($root_element, @available_domains));
  if (my $nesting = $new_file->first_child('nesting')) {
   insert_xml($include_for_domain{$root_element_domain}, "<define name='${root_element}-info-types'/>")->set_content(make_content_model($nesting->att('model')));
  } else {
   my $existing_info_types = (grep {$_} map {$_->get_xpath(".//define[\@name='${root_element}-info-types']")} @grammars_in_scope)[-1];  # TO-DO surely a better way!
   insert_xml($include_for_domain{$root_element_domain}, "<define name='${root_element}-info-types'/>")->set_content($existing_info_types->children_copy);
  }
 }
# TO-DO -- automatically include absolutely necessary modules for bare topicshell/mapshell modules defined with no domains
# (for example, a mapshell needs mapgroup-d)

 if ($new_file->matches('topicshell|mapshell')) {
  # ROOT ELEMENT DECLARATION
  insert_xml($root_element_declaration, '<start/>', "<ref name='${root_element}.element'/>");

  # DOMAINS ATTRIBUTE
  insert_xml($domains_attribute, '<define name="domains-att" combine="interleave"/>', '<optional/>', '<attribute name="domains" a:defaultValue="'.join(' ', (sort map {$domaincontribution_for_domain{$_}} (grep {defined($domaincontribution_for_domain{$_})} @available_domains_up))).'"/>');  # doesn't include root element ('topic' or 'map')

  # ID-DEFINING-ELEMENT OVERRIDES
  my $except = insert_xml($id_element_overrides, '<define name="any"><zeroOrMore><choice><ref name="idElements"/><element><anyName><except/></anyName><zeroOrMore><attribute><anyName/></attribute></zeroOrMore><ref name="any"/></element><text/></choice></zeroOrMore></define>')->first_descendant('except');
  insert_xml($except, "<name>$_</name>") for sort map({keys %{$idnames_for_domain{$_}}} (grep {defined($idnames_for_domain{$_})} @available_domains_up));
  insert_xml($except, "<nsName ns='$_'/>") for sort map({@{$idnamespaces_for_domain{$_}}} (grep {defined($idnamespaces_for_domain{$_})} @available_domains_up));
 }



 # create specialized element definitions and specialized/constrained content models (but no content model modifications yet)
 my %content_tag = () if $new_file->matches('elementdomain|topic|map|constraint');
 my %extra_define = () if $new_file->matches('elementdomain|topic|map|constraint');
 if ($new_file->matches('elementdomain|topic|map')) {
  my %specializations_of = ();
  foreach my $modification ($new_file->children('specialize')) {
   my ($from_domain, $from_tag) = domain_and_tag(add_domain($modification->att('from'), @available_domains));
   my ($base_domain, $base_tag) = base_domain_and_tag($from_domain, $from_tag);
   foreach my $new_tag (split /\s+/, $modification->att('elements')) {
    # ELEMENT TYPE NAME PATTERNS
    insert_xml($element_type_name_patterns, "<define name='$new_tag'/>", "<ref name='${new_tag}.element'/>");
    # ELEMENT TYPE DECLARATIONS
    my $div = insert_div($element_type_declarations, "LONG NAME: $new_tag");
    my $element = insert_xml($div, "<define name='${new_tag}.element'/>", "<element name='$new_tag' dita:longName='$new_tag'/>");
    insert_xml($element, "<ref name='${new_tag}.attlist'/>");
    insert_xml($element, "<ref name='${new_tag}.content'/>");

    croak "Can't re-specialize '$new_tag'" if defined($content_tag{$new_tag});
    $content_tag{$new_tag} = insert_xml($div, "<define name='${new_tag}.content'/>", "<ref name='${from_tag}.content'/>")->parent;
    my $attlist = insert_xml($div, "<define name='${new_tag}.attlist' combine='interleave'/>");
    insert_xml($attlist, "<ref name='${new_tag}.attributes'/>");
    insert_xml($attlist, "<ref name='arch-atts'/>") if $base_tag =~ m!^(topic|map)$!;  # TO-DO (low priority) there is some duplication here because ${new_tag}.attributes points to ${from_tag}.attributes, which also contains a ref to domains-att
    insert_xml($attlist, "<ref name='domains-att'/>") if $base_tag =~ m!^(topic|map)$!;  # TO-DO (low priority) there is some duplication here because ${new_tag}.attributes points to ${from_tag}.attributes, which also contains a ref to domains-att
    insert_xml($div, "<define name='${new_tag}.attributes'/>", "<ref name='${from_tag}.attributes'/>");
    # SPECIALIZATION ATTRIBUTE DECLARATIONS
    my $define = insert_xml($specialization_attribute_declarations, "<define name='${new_tag}.attlist' combine='interleave'/>");
    insert_xml($define, "<ref name='global-atts'/>");
    my $defaultvalue = $defaultvalue_of{$from_domain}->{$from_tag}."${new_domain}/${new_tag} ";
    $defaultvalue =~ s!^.!+! if $new_file->matches('elementdomain');  # change - to + for elementdomain
    insert_xml($define, "<optional/>", "<attribute name='class' a:defaultValue='$defaultvalue'/>");
    push @{$specializations_of{$base_tag}}, $new_tag unless ($modification->att('allow_by_default') or 'true') eq 'false';
    $idnames_for_domain{$new_domain}->{$new_tag} = 1 if defined($idnames_for_domain{$base_domain}->{$base_tag});
    if ($new_file->matches('topic')) {
     # INFO TYPES PATTERNS
     if (my $nesting = $modification->first_child('nesting')) {  # add a new info-types definition
      insert_xml($info_types_patterns, "<define name='${new_tag}-info-types'/>")->set_content(make_content_model($nesting->att('model')));
     } else {
      insert_xml($info_types_patterns, "<define name='${new_tag}-info-types'/>", "<ref name='${new_tag}.element'/>");
     }
     $modification->insert_new_elt('first_child', 'replace-info-type', {element => "${new_tag}", pattern => "${from_tag}-info-types", with => "${new_tag}-info-types"});  # update content model to point to it
    }
   }
  }
  # DOMAIN EXTENSION PATTERNS
  if ($new_file->matches('elementdomain')) {
   foreach my $root_tag (sort keys %specializations_of) {
    my $choice = insert_xml($domain_extension_patterns, "<define name='${new_domain}-$root_tag'/>", '<choice/>');
    insert_xml($choice, "<ref name='${_}.element'/>") for (sort @{$specializations_of{$root_tag}});
    insert_xml($domain_extension_patterns, "<define name='$root_tag' combine='choice'/>", "<ref name='${new_domain}-$root_tag'/>");
   }
  }
   elsif ($new_file->matches('topic')) {
   croak "At least one specialization of a topic is required in a topic module" if !defined($specializations_of{'topic'});
  }
 } elsif ($new_file->matches('constraint')) {
  foreach my $modification ($new_file->children('constrain')) {  # TO-DO - combine this with the following loop somehow
   foreach my $this_tag (split /\s+/, $modification->att('elements')) {
    my $this_domain = domain(add_domain($this_tag, @available_domains));
    my ($base_domain, $base_tag) = base_domain_and_tag($this_domain, $this_tag);
    if (my $nesting = $modification->first_child('nesting')) {
     croak "Can't specify nesting model for non-topic element '$this_tag'" if $base_tag ne 'topic';
     insert_xml($include_for_domain{$this_domain}, "<define name='${this_tag}-info-types'/>")->set_content(make_content_model($nesting->att('model')));  # TO-DO - why do I need to specify topic.element with com.synopsys.docshell?
    }
   }
  }
  foreach my $this_tag (grep {!defined($content_tag{$_})} uniq map {split /\s+/, $_->att('elements')} $new_file->children('constrain')) {  # TO-DO - only build new content module if non-nesting module action specified
   my $this_domain = domain(add_domain($this_tag, @available_domains));
   my $original_define = (grep {$_} map {$_->get_xpath(".//define[\@name='${this_tag}.content']")} @grammars_in_scope)[-1];  # TO-DO surely a better way!
   my $this_extra = $extra_define{$this_tag} = insert_xml($extra_content_models, "<define name='${this_tag}.content__${new_domain}'/>");
   $this_extra->set_content($original_define->children_copy);
   my $this_define = $content_tag{$this_tag} = insert_xml($include_for_domain{$this_domain}, "<define name='${this_tag}.content'/>", "<ref name='".$this_extra->att('name')."'/>");
  }
 }

 # apply any content model modifications
 if ($new_file->matches('elementdomain|topic|map|constraint')) {
  # create extra-content-model redirection defines for elements we're going to modify
  my $itr = 1;
  foreach my $action (map {$_->children('disallow|content|replace|replace-info-type')} $new_file->children('specialize|constrain')) {
   my @tags_to_modify = split /\s+/, ($action->matches('replace-info-type') ? $action->att('element') : $action->parent->att('elements'));
   my %subelements = map {$_ => 1} (split /\s+/, ($action->att('elements') or ''));
   my %xin = map {$_ => 1} split /\s+/, ($action->att('in') or '.');
   # <disallow> finds ref name="ELEM.element"
   # <content> finds define name="ELEM.content"

   # create any needed redirection defines before we create content models
   my %invariant_names = ();
   foreach my $this_tag (grep {!defined($extra_define{$_})} @tags_to_modify) {
    my $this_define = $content_tag{$this_tag};
    my $this_extra = $extra_define{$this_tag} = $this_define->copy->move('last_child', $extra_content_models);
    $this_extra->latt('name') .= "__${new_domain}";
    $this_define->set_content(my_parse("<ref name='".$this_extra->att('name')."'/>"));
   }
   $invariant_names{"${_}.content"} = $invariant_names{"${_}.content__${new_domain}"} = 1 for @tags_to_modify;

   # if we're modifying *this* content model and no further
   if ($action->matches('content') && defined($xin{'.'})) {
    $extra_define{$_}->set_content(make_content_model($action->att('model'))) for @tags_to_modify;
    next;
   }

   # make a cross-reference of all defines by name, taking include overrides into account
   my @all_defines_in_scope = map {$_->get_xpath('.//define[@name!~/\.(attlist|attributes)$/]')} @grammars_in_scope;  # cache for speed - only valid for this loop because the defineswill be different for the next action
   my %defines_by_name = ();
   foreach my $define (@all_defines_in_scope) {
    my $define_name = $define->att('name');
    @{$defines_by_name{$define_name}} = () if $define->parent_matches('include');  # forget previous definitions if this is an include override
    push @{$defines_by_name{$define_name}}, $define;
   }
   @all_defines_in_scope = map {@{$defines_by_name{$_}}} sort keys %defines_by_name;  # rebuild list *without* overridden defines

   # get *all* flavors of element/content definitions in our grammar scope (which is larger than the element scope we're modifying, so we can't blindly modify all these)
   my %element_patterns_of = ();  # $element_patterns_of{'FOO'} = ('FOO.element', 'FOO.element__specialized', ...)
   my %content_patterns_of = ();  # $content_patterns_of{'FOO'} = ('FOO.content', 'FOO.content__specialized', ...)
   foreach my $this_element (grep {$_} map {$_->first_child('element')} @all_defines_in_scope) {  # TO-DO  cache is_element globally
    (my $this_define = $this_element->parent)->set_att('#element', 1);
    push @{$element_patterns_of{$this_element->att('name')}}, $this_define->att('name');
    push @{$content_patterns_of{$this_element->att('name')}}, (($this_element->get_xpath('.//ref[@name=~/\.content/]'))[0])->att('name');
   }
   my %refs_to_replace = map {$_ => 1} map {@{$element_patterns_of{$_}}} (keys %subelements) if $action->matches('disallow|replace');
   my %defs_to_remodel = map {$_ => 1} map {@{$content_patterns_of{$_}}} (keys %xin) if $action->matches('content');

   ### SUPER SUPER HACKY (and super super temporarily, I hope) - yes I am ashamed of myself
   if ($action->matches('replace-info-type')) {
    $refs_to_replace{$action->att('pattern')} = 1;
   }

   # trace the forward (ref-to-def) paths from specialized content models for this disallow pattern
   # and capture the backward (previous-define) references
   my %prev_defs = ();
   my @defines_to_copy = ();
   my @defines_to_trace = map {$extra_define{$_}} @tags_to_modify; # start at the elements we're modifying  ## TO-DO - for constraint modules, this should also search for and include previously modified tags whose definitions are only in $extra_content_models
#print $_->sprint."\n" for @defines_to_trace;
   while (my $this_define = shift @defines_to_trace) {
    next if $this_define->att('#fwd');  # only process this define once
#print "FWD:".$this_define->start_tag."\n";
    $this_define->set_att('#fwd', 1);

    if ($action->matches('content')) {
     if (defined($defs_to_remodel{$this_define->att('name')})) {
      push @defines_to_copy, $this_define;
      next;
     }
    }

    my @ref_names = uniq map {$_->att('name')} $this_define->descendants('ref');
    if ($action->matches('disallow|replace|replace-info-type')) {
     if (my @disallowed_refs = (grep {defined($refs_to_replace{$_})} @ref_names)) {
      push @defines_to_copy, $this_define;
      @ref_names = minus(\@ref_names, \@disallowed_refs);  # don't trace through disallowed or replaced references (for now - we should handle this properly by integrating tracing and modification together - TO-DO)
     }
    }

    next if $this_define->att('#element') && defined($xin{'.'});  # definitely don't trace into subelements if we're not told to modify them

    for my $ref_name (@ref_names) {
     push @{$prev_defs{$ref_name}}, $this_define;  # remember the define backreferences
     push @defines_to_trace, grep {!$_->att('#fwd')} @{$defines_by_name{$ref_name}};
    }
   }

   # trace backward and collect defines to be modified
   while (my $this_define = shift @defines_to_copy) {
    next if $this_define->att('#copy');  # only process this define once
    $this_define->set_att('#copy', 1);
#print "CPY:".$this_define->start_tag."\n";
    push @defines_to_copy, grep {!$_->att('#copy')} @{$prev_defs{$this_define->att('name')}};
   }
 
   my ($copied_defines, $uncopied_defines) = part {$_->att('#copy') ? 1 : 0} @all_defines_in_scope;
   my %copied_define_names = map {$_->att('name') => 1} @{$copied_defines};
   my %uncopied_define_names = map {$_->att('name') => 1} @{$uncopied_defines};
   my $suffix = "__${new_domain}".$itr++;

   foreach my $this_define (@{$copied_defines}) {
    my $this_define_name = $this_define->att('name');
    $this_define->set_content(make_content_model($action->att('model'))) if defined($defs_to_remodel{$this_define_name});
    if (!defined($invariant_names{$this_define_name})) {
     ($this_define = $this_define->copy)->move('last_child', $extra_content_models);
     $this_define->latt('name') .= $suffix;
#print $this_define->sprint."\n";
    }
    my @refs = $this_define->descendants('ref');
    do {$_->replace_with(my_elt->new('#COMMENT', $_->sprint)) for grep {defined($refs_to_replace{$_->att('name')})} @refs} if $action->matches('disallow');
    do {$_->replace_with(make_content_model($action->att('with'))) for grep {defined($refs_to_replace{$_->att('name')})} @refs} if $action->matches('replace|replace-info-type');
    foreach my $ref (grep {defined($copied_define_names{$_->att('name')})} @refs) {
     if (defined($uncopied_define_names{$ref->att('name')})) {
      my $div = ($ref->insert_new_elt('after', 'div'));
      $_->copy->insert('after', $div) for map {$_->children} grep {$_->att('name') eq $ref->att('name')} @{$uncopied_defines};
     }
     $ref->latt('name') .= $suffix if !defined($invariant_names{$ref->att('name')});
    }
   }
#$new_grammar->my_print_to_file('ng0.rng', pretty_print => 'indented');
   $_->strip_att('#fwd') for @grammars_in_scope;
   $_->strip_att('#copy') for @grammars_in_scope;
  }
  #$_->strip_att('#fwd') for @grammars_in_scope;
  #$_->strip_att('#copy') for @grammars_in_scope;
  #$_->strip_att('#donotcopy') for @grammars_in_scope;

  # simplify new content models
#$new_grammar->my_print_to_file('ng1.rng', pretty_print => 'indented');
  while (1) {
   my $changes = 0;

   # collapse nested choices
   if (my @nested_choices = $extra_content_models->get_xpath('.//choice/choice')) {
   	$_->erase for @nested_choices;
   	next;  # make sure we collapse fully before doing the following simplifications
   }

   # inline any defines that consist only of comments now
   foreach my $this_define (grep {!$_->has_children('#ELT')} $extra_content_models->descendants('define')) {
    $_->replace_with($this_define->children_copy) for $extra_content_models->get_refs_to($this_define->att('name'));
    $this_define->delete;
    $changes++;
   }

   # if there is a single reference to a define, both within our extra content models, inline that define
   my %origrefcount = ();
   my %extrarefcount = ();
   $origrefcount{$_}++ for map {$_->att('name')} ($element_type_declarations or $content_model_overrides)->descendants('ref');
   $extrarefcount{$_}++ for map {$_->att('name')} $extra_content_models->descendants('ref');
   foreach my $ref_name (grep {$extrarefcount{$_} == 1 && !defined($origrefcount{$_})} keys %extrarefcount) {
#print "$ref_name\n";
    if (my $this_define = $extra_content_models->get_def_of($ref_name)) {
     if (!$this_define->first_child('element')) {  # do not inline element definitions
      $extra_content_models->get_ref_to($ref_name)->replace_with($this_define)->erase;
      $changes++;
     }
    }
   }

   # un-empty any empty groups
   foreach my $this_group (grep {!$_->has_children('#ELT')} $extra_content_models->descendants('choice|zeroOrMore|oneOrMore|optional')) {
    $this_group->insert_new_elt('first_child', 'empty');
   	$changes++;
   }

   last if !$changes;
  }
#$new_grammar->my_print_to_file('ng2.rng', pretty_print => 'indented');
 }
 $extra_content_models->delete if $extra_content_models && !$extra_content_models->has_children('define|div');

 # add <domainsContribution>
 if ($new_file->matches('elementdomain|topic|map|constraint')) {
  insert_xml($new_grammar->first_descendant('moduleMetadata'), "<domainsContribution>(@available_domains_up ${new_domain})</domainsContribution>");
 }

 my $rngtype = $new_file->matches('topicshell|mapshell') ? 'rngShell' : 'rngMod';
 $new_grammar->first_descendant('modulePublicIds')->set_content(my_parse("<${rngtype}>${urn}<var presep=':' name='ditaver'/></${rngtype}>"));

 # output our template
 $new_grammar->twig->my_print_to_file($full_output_filename, pretty_print => 'indented');
 $new_grammar->set_att('base_output_filename', $base_output_filename);
 $new_grammar->set_att('#pfile', adjust_local_path($full_output_filename, '.'));
 process_grammar($new_grammar);
 reorder_grammars();
 process_ordered_grammar($new_grammar);
 insert_xml($catalog, "<uri name='$uri_prefix:$base_output_filename' uri='rng/$base_output_filename'/>");
 insert_xml($catalog, "<system systemId='$uri_prefix:$base_output_filename' uri='rng/$base_output_filename'/>");

 # for document-type shells, write an example .dita file that uses the shell
 if ($new_file->matches('topicshell|mapshell')) {
  my $templatefilename = File::Spec->catdir($template_directory, $module_title.'.dita');
  print "  Creating '".basename($templatefilename)."'...\n";
  my $templatetwig = my_twig->new(elt_class => 'my_elt')->parse('<?xml version="1.0" encoding="utf-8"?><?xml-model href="'.$urn.'" schematypens="http://relaxng.org/ns/structure/1.0"?><START id="reference_${id}"></START>');
  $templatetwig->root->set_tag($new_file->first_child_text('root_element'));
  $templatetwig->root->insert_new_elt('first_child', 'title', '${caret}') if $new_file->matches('topicshell');
  $templatetwig->my_print_to_file($templatefilename, pretty_print => 'indented');  
 }
}

print " Creating '".basename(my $catfilename = File::Spec->catdir($plugin_directory, 'catalog.xml'))."'...\n";
$catalogtwig->my_print_to_file($catfilename, pretty_print => 'indented');

print " Creating '".basename(my $pluginfilename = File::Spec->catdir($plugin_directory, 'plugin.xml'))."'...\n";
my $plugintwig = my_twig->new(elt_class => 'my_elt')->parse('<?xml version="1.0" encoding="UTF-8"?><plugin id="REPLACEME"><feature extension="dita.specialization.catalog.relative" file="catalog.xml"/></plugin>');
$plugintwig->root->set_att('id', basename($plugin_directory));
$plugintwig->my_print_to_file($pluginfilename, pretty_print => 'indented');




########################################
# HELPER SUBROUTINES

sub get_rng_files {
 my @files = ();
 find({ wanted => sub { push @files, $File::Find::name if (m!\.rng$! && !m!y\.rng$!); }, follow => 1 }, @_);
 return @files;
}

sub get_all_files {
 my @files = ();
 find({ wanted => sub { push @files, $File::Find::name; }, follow => 1 }, @_);
 return @files;
}

sub domain { return ($_[0] =~ m!^(.*)\/!g)[0]; }
sub tag { return ($_[0] =~ m!\/(.*)$!g)[0]; }
sub domain_and_tag { return ($_[0] =~ m!^(.*)\/(.*)$!g); }
sub base_domain_and_tag { return ($base_domain_of{$_[0]}->{$_[1]}, $base_element_of{$_[0]}->{$_[1]}); }

# insert a <div> element with a documentation tag
sub insert_div {
 my ($parent, $doc) = @_;
 my $div = ($parent->insert_new_elt('last_child', 'div'));
 $div->insert_new_elt('first_child', 'a:documentation', $doc);
 return $div;
}

# insert a series of XML elements, each placed inside the last
sub insert_xml {
 my $parent = shift;
 $parent = my_parse($_)->move('last_child', $parent) for @_;
 return $parent;
}

sub ensure_one {
 croak "Expecting one match but got two: @_" if scalar(@_) > 1;
 return $_[0];
}

sub adjust_local_path {
 my ($file, $relative_to) = @_;
 return Cwd::realpath($file) if (($relative_to eq '.') || ($file =~ m!^\/!));  # handle the fast cases
 return $pfile_for_urn{$file} if defined($pfile_for_urn{$file});  # if $file is a urn

 $relative_to = dirname($relative_to) if (-f $relative_to);
 $relative_to = Cwd::realpath($relative_to);
 while ($file =~ s!^\.\./!!) {
  $relative_to =~ s!/[^/]+$!!;
 }
 return File::Spec->catdir($relative_to, $file);
}

sub add_domain {
 my ($tag, @possible_domains) = @_;
 if (my $d = domain($tag)) {
  @possible_domains = ($d);
  $tag = tag($tag);
 }
 my @domains_that_provide_tag = (keys %{$domains_that_define_element{$tag}}) or croak "Unknown element '$tag'";
 
 if (@possible_domains) {
  @possible_domains = intersect(\@domains_that_provide_tag, \@possible_domains);
 } else {
  @possible_domains = @domains_that_provide_tag;
 }
 croak "Unavailable element '$tag'" if !@possible_domains;
 croak "Ambiguous reference to element '$tag'; qualify with one of '@possible_domains'" if @possible_domains > 1;
 return "$possible_domains[0]/$tag";
}

sub my_parse {
 return my_twig->new(elt_class => 'my_elt')->parse(shift)->root->cut;
}

sub included_pfile {
 my $i = shift;
 $i->set_att('#included_pfile', adjust_local_path($i->att('href'), $i->inherit_att('#pfile', 'grammar'))) if !$i->att('#included_pfile');
 return $i->att('#included_pfile');
}

sub make_content_model {
 my ($pattern, $attflag) = @_;
 return my_parse('<empty/>') if $pattern eq '';
 my %connectors = ('|' => 'choice', '&' => 'interleave', ',' => 'div');
 my %quantifiers = ('*' => 'zeroOrMore', '+' => 'oneOrMore', '?' => 'optional');
 my $top = my_elt->new('content_model');
 my $current_group = $top->insert_new_elt('last_child', 'div');
 foreach my $token ($pattern =~ m{((?<!\\)\(|(?<!\\)\)|\*|\+|\?|\&|\||,|(?:[\w\-\._]|\\.)+)}g) {
  if (defined($connectors{$token})) {
   if (!$current_group->att('#connector')) {
    $current_group->set_tag($connectors{$token});
    $current_group->set_att('#connector', $token);
   } else {
    croak "Expected '".$current_group->att('#connector')."' connector but encountered '$token' instead" if $token ne $current_group->att('#connector');
   }
  } elsif (defined($quantifiers{$token})) {
   $current_group->last_child->wrap_in($quantifiers{$token});
  } elsif ($token eq '(') {
   $current_group = $current_group->insert_new_elt('last_child', 'div');
  } elsif ($token eq ')') {
   $current_group = $current_group->parent;
  } else {
   $token =~ s!\\(.)!$1!g;  # remove escaping backslashes
   if ($attflag) {
    $current_group->insert_new_elt('last_child', 'value', $token);  # for attributes, build string value elements
   } else {
    if ($token eq 'text') {
     $current_group->insert_new_elt('last_child', 'text');
    } else {
     $token =~ s!\\!!g;
     $current_group->insert_new_elt('last_child', ref => {name => "${token}"});
    }
   }
  }
 }
 $top->strip_att('#connector');
 $_->erase for $top->descendants('div');
 while (my @nested_choice = $top->get_xpath('.//choice/choice')) { $_->erase for @nested_choice; }
 $top->insert('list') if $attflag;
 return $top->cut_children;
}

sub get_ditaot_dir {
 my $dita = `which dita` or return undef;
 $dita =~ s!(^\s+|\s+$)!!m;  # remove end-of-line stuff
 croak "'$dita' is not a file\n" if !-f $dita;
 my $ditaotfull = realpath(dirname(realpath(dirname(realpath($dita)))));  # this funny thing resolves filesystem links at any intermediate level
 croak "'$ditaotfull' is not a directory\n" if !-d $ditaotfull;
 print "  Using DITA-OT installation at '$ditaotfull'.\n";
 return $ditaotfull;
}


########################################
# CUSTOM TWIG HANDLERS

package my_twig;
use XML::Twig;
use Carp qw(croak);
use base 'XML::Twig';

sub my_print_to_file {
 my ($twig, $filename) = @_;
 my $xml = $twig->sprint(pretty_print => 'indented');
 $xml =~ s{^\s*(<\?[^>]+\?>)\s*(<\?[^>]+\?>)\s*}{$1\n$2\n};  # fix <?xml version?>, <?xml-model?>
 open(my $fh, ">$filename") or die "can't open $filename for write: $!";
 print $fh $xml;
 close $fh;
}


########################################
# CUSTOM ELT HANDLERS

package my_elt;
use XML::Twig;
use Carp qw(croak);
use base 'XML::Twig::Elt';

sub ensure_one {
 croak "Expecting one match but got two: @_" if scalar(@_) > 1;
 return $_[0];
}

sub rngname {
 my ($elt, $name) = @_;
  return $elt->att('name');
}

sub get_refs_to {
 my ($elt, $name) = @_;
  return $elt->descendants("ref[\@name='$name']");
}

sub get_ref_to {
 my ($elt, $name) = @_;
  return ensure_one($elt->get_refs_to($name));
}

sub get_defs_of {
 my ($elt, $name) = @_;
  return $elt->descendants("define[\@name='$name']");
}

sub get_def_of {
 my ($elt, $name) = @_;
  return ensure_one($elt->get_defs_of($name));
}

sub children_atts {
 my ($elt, $pat, $att) = @_;
 return map {$_->att($att)} $elt->children($pat);
}




=head1 NAME

make_dita_grammar - make DITA RelaxNG grammar modules from a high-level description

=head1 SYNOPSIS

  <input_filename>
          Path to XML file that defines one or more grammar modules to create
  [--ditaot <path>]
          Location of DITA-OT directory
          (default is to use DITA-OT of 'dita' found in search path)
  [--verbose, -v]
          Show additional information about grammar creation

=head1 VERSION

0.50

=cut
