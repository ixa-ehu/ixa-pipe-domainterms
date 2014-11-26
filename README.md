# ixa-pipe-domainterms

*ixa-pipe-domainterms* is a domain tagger. Given a dictionary for a
specific domain, the *ixa-pipe-domainters* module takes a [NAF
document](http://wordpress.let.vupr.nl/naf/) containing *wf* and
*term* elements as input, recognizes terms on the given dictionary,
and outputs a NAF document with those terms tagged on *markables*
element (`<markables source="ixa-pipe-domainterms">`)

*ixa-pipe-domainterms* is part of IXA pipes, a [multilingual NLP
pipeline](http://ixa2.si.ehu.es/ixa-pipes) developed by the [IXA NLP
Group](http://ixa.si.ehu.es/Ixa).


## USAGE

The *ixa-pipe-domainterms* requires a NAF document (with *wf* and
*term* elements) as standard input and outputs NAF through standard
output. You can get the necessary input for *ixa-pipe-domainterms* by
piping *[ixa-pipe-tok](https://github.com/ixa-ehu/ixa-pipe-tok)* and
*[ixa-pipe-pos](https://github.com/ixa-ehu/ixa-pipe-pos)* as shown in
the example below.

A dictionary file is required. There are two possible formats for the
dictionary file:
+ plain text file: one dictionary entry per line formatted as
```
dictionary_entry||entry_id||class_id
```
An entry example is shown here

    tiempo de reformas||ID-89||CID-445

+ JSON file: a *data* array, which elements have (at least) these
elements: *id*, *desc* (dictionary entry name) and *idclass* (id of
entry's class). An example is shown here
```
{"data":[
{"id":"ICD-1-P","desc":"P","idclass":"","nivel":"1"},
{"id":"ICD-1-S","desc":"S","idclass":"","nivel":"1"},
{"id":"ICD-2-1","desc":"Autenticación y certificación digital","idclass":"ICD-1-P","nivel":"2"},
{"id":"ICD-2-2","desc":"Tiempo_de_reformas","idclass":"ICD-1-P","nivel":"2"},
{"id":"ICD-2-3","desc":"Control de tráfico de red","idclass":"ICD-1-S","nivel":"2"}]}
```

There are several parameters:
+ **D** (required): specify the dictionary file as parameter.
+ **j** (optional): use this parameter if the dictionary file is formatted as JSON instead of plain text file.

You can call to *ixa-pipe-domainterms* module as follows:
```
cat text.txt | ixa-pipe-tok | ixa-pipe-pos | perl ixa-pipe-domainterms.pl -D dict.txt
```
or
```
cat text.txt | ixa-pipe-tok | ixa-pipe-pos | perl ixa-pipe-domainterms.pl -D dict.json -j
```


#### Contact information

    Arantxa Otegi
    arantza.otegi@ehu.es
    IXA NLP Group
    University of the Basque Country (UPV/EHU)
    E-20018 Donostia-San Sebastián


