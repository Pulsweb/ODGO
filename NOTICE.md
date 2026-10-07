# Notices and attribution

## pbigtwmonitor

ODGO (On-premises Data Gateway Observability) is a modernization of **pbigtwmonitor** by Rui Romano
(<https://github.com/RuiRomano/pbigtwmonitor>, commit `cbc884a9`, archived). It reuses and adapts:

* the semantic model: tables, columns, measures, relationships and formatting, converted to a TMDL Direct Lake
  model;
* the report: pages, visuals, formatting, tooltips, drillthrough and the base theme, converted to the PBIR format;
* the knowledge of the gateway log formats encoded in its Power Query transformations, re-implemented in Python in
  `nb_gwmon_lib`.

pbigtwmonitor is distributed under the MIT License:

```text
MIT License

Copyright (c) 2022 Rui Romano

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Power BI base theme

`powerbi/GatewayMonitor.Report/StaticResources/SharedResources/BaseThemes/CY22SU03.json` is the Power BI base theme
that Power BI Desktop writes into every report definition. It was taken unchanged from the original pbigtwmonitor
report definition.

## Fabric Platform Monitoring (inspiration only)

The design of ODGO was inspired by
[Fabric Platform Monitoring](https://github.com/microsoft/fabric-toolbox/tree/main/monitoring/fabric-platform-monitoring)
(Microsoft Fabric Toolbox, MIT License), notably its gateway heartbeat monitoring. No code, query, script or asset from
Fabric Platform Monitoring is included in this repository, so no license notice is required. A line-by-line
comparison found a few identical DAX lines in the semantic model (the *System Counters* measures and the counters
field parameters). Both projects inherited them from pbigtwmonitor, whose notice is above. Fabric Platform Monitoring
is credited in the README.

## Trademarks

Microsoft, Microsoft Fabric, Power BI, OneLake, Azure and Microsoft Entra are trademarks of the Microsoft group of
companies. This project isn't affiliated with, endorsed by or supported by Microsoft.
