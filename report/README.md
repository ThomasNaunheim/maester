# Maester Test Report

This folder contains the test report for the Maester project.

Vite and `vite-plugin-singlefile` generate the self-contained HTML template used by
`Get-MtHtmlReport`. The production bundle uses Preact's React-compatible runtime.

## Developer guide

### Pre-requisites

- [Node.js](https://nodejs.org/en/download/) version 20.0 or above (which can be checked by running `node -v`). You can use [nvm](https://github.com/nvm-sh/nvm) for managing multiple Node versions on a single machine installed.
- When installing Node.js, you are recommended to check all checkboxes related to dependencies.

### First time run

Open terminal window and navigate to /report folder and run the following command to install all dependencies:

```shell
npm install
```

### Development

To start the development server, run the following command:

```shell
npm run dev
```

### Build

Once you are done with making updates to the report, you can build the project to create the .html template and copy it over to the /powershell folder.

To build the project, run the following command:

```shell
npm run build
```

- This will generate the `index.html` file in the `/dist` folder.
- Copy it to the /powershell/assets folder and rename it to ReportTemplate.html (overwrite the existing file).

```powershell
Copy-Item ./dist/index.html ../powershell/assets/ReportTemplate.html -Force
```

- Now PowerShell will package and use the new report template.

When you also want to build and import the module in one step, use the build helper instead of
the manual copy (it runs `npm run build`, copies the template, then builds and imports the module):

```powershell
./build/Build-LocalMaester.ps1 -BuildReport
```

### Stale template troubleshooting

`powershell/assets/ReportTemplate.html` is a build artifact that is only refreshed by the
[build-maester-report-template](https://github.com/maester365/maester/blob/main/.github/workflows/build-maester-report-template.yaml)
workflow, so a local clone can carry a template that predates recent `/report/src` changes.
Symptom: `Invoke-Maester` embeds the data correctly but the UI ignores it — for example
`-IncludeAssetInventory` writes `<name>-assets.json` and the html contains `"AssetInventory":[...]`,
yet the report's sidebar has no **Assets** entry.

To confirm the template, not the data, is at fault, check whether the bundled JavaScript knows
about the property at all:

```shell
grep -c 'AssetInventory' powershell/assets/ReportTemplate.html
```

A count of `0` means the template is stale — rebuild it with the steps above. Remember to copy
it to `module/assets/ReportTemplate.html` too if you are running the built module from `./module`
rather than importing from `./powershell`.

### Updating the sample data in the report

When making updates to the report, use the matching JSON report output as sample
data. Replace the `testResults` object in `/report/src/lib/testResults.ts`; the
development server loads this fixture directly. Production HTML reads injected JSON
from its dedicated data element, so generated HTML is not the source fixture.

### Submitting a Pull-Request

When submitting a PR for changes in `/report/src` you can skip updating the `/powershell/assets/ReportTemplate.html` artifact. The [build-maester-report-template](https://github.com/maester365/maester/blob/main/.github/workflows/build-maester-report-template.yaml) workflow automatically builds and includes an updated ReportTemplate as part of the module publish pipeline.
