# DITA-plugin-utilities

This is a collection of utilities intended to make it easier to create customized DITA grammars:

* `make_dita_grammar.pl` - make DITA RelaxNG grammar plugin modules from high-level descriptions
* `content_model.pl` - show the content model of a DITA RelaxNG topicshell or mapshell module

## Getting Started

You can run these utilities on a native linux machine, or on a Windows 10 machine that has Windows Subsystem for Linux (WSL) installed.

### Prerequisites

Before using them, you must install the following prerequisites:

```
sudo apt update
sudo apt install cpanminus default-jre jing trang
sudo cpanm install XML::Twig Acme::Tools
```

Only `content_model.pl` requires default-jre, jing, and trang.

Only `make_dita_grammar.pl` requires Acme::Tools.

### Installing

Download or clone the repository, then put its `bin/` directory in your search path.

For example, in the default bash shell, add this line to your `\~/.profile` file:

```
PATH=~/DITA-plugin-utilities/bin:$PATH
```

## Usage

### make_dita_grammar.pl

This utility takes a high-level XML description of a DITA grammar as input, then creates a DITA grammar plugin directory as output. The plugin directory is complete and ready to put into your DITA-OT plugins/ directory for integration.

Run it with no arguments or with `-help` to see the usage:

```
$ make_dita_grammar.pl
Usage:
      <input_filename>
              Path to XML file that defines one or more grammar modules to create
      [--ditaot <path>]
              Location of DITA-OT directory
              (default is to use DITA-OT of 'dita' found in search path)
      [--verbose, -v]
              Show additional information about grammar creation
```

`make_dita_grammar.pl` analyzes the existing DITA RelaxNG files to understand what modules and elements already exist. By default, it looks for the `dita` command in your search path and uses the `<DITA-OT>/plugins/` directory from that installation. If you want to specify a different DITA-OT installation path, use the `--ditaot` option.

The `input_filename` is the location of the high-level XML description of the DITA grammar you want to create. All information relating to plugin creation, including the output directory name, is contained in this input file.

**I still need to write proper documentation for the input format**, and I should probably create a RelaxNG schema to define what is legal input to `make_dita_grammar.pl`. In the meantime, have a look at the commented example files in the `examples/` directory.

### content_model.pl

This utility reports the content model of a DITA topicshell or mapshell module in a simple form (similar to *compact* RelaxNG).

Run it with no arguments or with `-help` to see the usage:

```
$ content_model.pl
Usage:
      <module_filename>
              Path to <topicshell> or <mapshell> DITA module (.rnc or .rng)
      [--ditaot <path>]
              Location of DITA-OT directory
              (default is to use DITA-OT of 'dita' found in search path)
      [--attributes none | common | all]
              Determine which attributes to show
              (default 'common')
      [--attvalues, --noattvalues]
              Determine whether to show attribute value content models
              (default is no values)
      [--split, --nosplit]
              Determine whether to allow element definitions to split across lines
              (default is not to split)
      [--verbose, -v]
              Show maximal information about the content model
              (equivalent to '--attributes all --attvalues --split')
```

`content_model.pl` uses the `catalog-dita.xml` file in your DITA-OT installation to resolve URN references to modules. By default, it looks for the `dita` command in your search path and uses the catalog file from that installation. If you want to specify a different DITA-OT installation path, use the `--ditaot` option.

By default, the utility hides "common" DITA attributes, defined as attributes that are common to 95% of the elements. You can use the `--attributes` option to determine which attributes to show.

By default, the utility does not report the content models of attributes (one-of-value and such). Use the `--attvalues` option to show the content model of attributes.

By default, the utility puts the entire content model of an element on a single line. This makes it easy to `grep` particular elements out of the results, but it can make things crowded when you're showing attributes and attribute content models. To allow element content models to span multiple lines, use the `--split` option.

If there are context-specific content models, numeric suffixes are appended to the element names to differentiate their models and contexts. These suffixes are for reporting only; the elements themselves are still used by their name.

## Examples

To demonstrate both utilities, try the following:

```
cd examples
make_dita_grammar.pl ex1.xml
content_model.pl ex1/rng/myTopicShell.rng
```

You can repeat this for the other examples in the directory.

## Limitations and Caveats

* I don't have a computer science degree. There are plenty of places where the code is messy and I don't have the time or expertise to improve it.

* The syntax of the input XML file might change in the future (but hopefully always for the better!).

* Content model modification is not robust yet. In particular, I need to improve the handling of applying successive modifications to the same content models.

* [A bug in `jing`](https://github.com/relaxng/jing-trang/issues/225) causes `content_model.pl` to crash when processing topics that include the DITA `svg-d` domain, such as topic.rng or task.rng in technicalContent/rng.

  To work around this, run the following commands on your DITA-OT:

    ```
    sed -i 's/<!DOCTYPE .*>//' ${PATH_TO_DITAOT}/plugins/org.oasis-open.dita.v1_3/rng/technicalContent/rng/svg/svg11/*.rng
    sed -i 's/<!DOCTYPE .*>//' ${PATH_TO_DITAOT}/plugins/org.oasis-open.dita.techcomm.v2_0/rng/technicalContent/svg/svg11/*.rng
    ```

## Author

My name is Chris Papademetrious. I'm a technical writer with [Synopsys Inc.](https://www.synopsys.com/), a semiconductor design and verification software company.

I found DITA conceptually promising but practically hard to use. In particular, I found constraints and specializations particularly difficult to create. I started writing a simple perl script to automate specializations in DITA RelaxNG schemas. And that grew into this.

## License

This project is licensed under the GPLv3 license - see the [LICENSE.md](LICENSE.md) file for details.

## Acknowledgments

These utilities would not be possible without help from:

* [Synopsys Inc.](https://www.synopsys.com/) (my employer), for allowing me to share my work with the DITA community.

* [Michel Rodriguez](xmltwig@gmail.com), who created [XML::Twig module](https://metacpan.org/pod/XML::Twig) and other [amazingly useful perl modules](https://metacpan.org/author/MIROD) and supports them with energy and passion.

* [Eliot Kimber](https://www.google.com/search?q=eliot+kimber+dita), for tirelessly answering my unending stream of questions about the inner workings of DITA RelaxNG schema files.
