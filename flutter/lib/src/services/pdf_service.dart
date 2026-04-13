import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';

import '../models/client.dart';

class PdfService {
  Future<File> generateWarrantyPdf({
    required Client client,
    required String customerName,
    required String customerAddress,
    required String siteAddress,
    required String mobileNumber,
    required DateTime startDate,
    required int durationYears,
    required String franchiseeName,
    required String warrantyCardNumber,
  }) async {
    final blueBgData =
        await rootBundle.load('assets/pdf-images/blueBuildingsBackground.png');
    final blueBg = pw.MemoryImage(blueBgData.buffer.asUint8List());

    final damsureLogoData =
        await rootBundle.load('assets/pdf-images/damsureLogo.png');
    final damsureLogo = pw.MemoryImage(damsureLogoData.buffer.asUint8List());

    final drySpotWhiteData =
        await rootBundle.load('assets/pdf-images/drySpotLogoWhite.png');
    final drySpotWhite = pw.MemoryImage(drySpotWhiteData.buffer.asUint8List());

    final drySpotBlueData =
        await rootBundle.load('assets/pdf-images/drySpotLogoBlue.png');
    final drySpotBlue = pw.MemoryImage(drySpotBlueData.buffer.asUint8List());

    final sealData = await rootBundle.load('assets/pdf-images/drySpotSeal.png');
    final seal = pw.MemoryImage(sealData.buffer.asUint8List());

    final signData = await rootBundle
        .load('assets/pdf-images/franchiseeManagerNameAndSign.jpg');
    final sign = pw.MemoryImage(signData.buffer.asUint8List());

    final pdf = pw.Document();

    final pageFormat = PdfPageFormat.a4.landscape;

    final blueColor = PdfColor.fromHex('#2a4f9a');
    final yellowColor = PdfColor.fromHex('#f7bf2e');
    final ink700 = PdfColor.fromHex('#303542');

    // Spread 1: Products & Warranty (Left) + T&C I (Right)
    pdf.addPage(pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (context) {
          return pw.Stack(children: [
            // Spine
            pw.Positioned(
                left: pageFormat.width / 2 - 2,
                top: 0,
                bottom: 0,
                child: pw.Container(width: 4, color: PdfColors.grey200)),
            // Left Panel: Products & Warranty
            pw.Positioned(
                left: 0,
                top: 0,
                child: pw.SizedBox(
                    width: pageFormat.width / 2,
                    height: pageFormat.height,
                    child: pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(
                            horizontal: 25, vertical: 25),
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Align(
                                alignment: pw.Alignment.topRight,
                                child: pw.Image(drySpotBlue, width: 100),
                              ),
                              pw.Center(
                                child: pw.Text('Products & Warranty',
                                    style: pw.TextStyle(
                                        color: blueColor,
                                        fontSize: 18,
                                        fontWeight: pw.FontWeight.bold)),
                              ),
                              pw.SizedBox(height: 10),
                              // Table
                              pw.Table(
                                  border: pw.TableBorder.all(
                                      color: ink700, width: 0.5),
                                  children: [
                                    pw.TableRow(children: [
                                      pw.Padding(
                                          padding: const pw.EdgeInsets.all(4),
                                          child: pw.Text('Product Name',
                                              style: pw.TextStyle(
                                                  fontSize: 9,
                                                  fontWeight:
                                                      pw.FontWeight.bold))),
                                      pw.Padding(
                                          padding: const pw.EdgeInsets.all(4),
                                          child: pw.Text('Qty',
                                              style: pw.TextStyle(
                                                  fontSize: 9,
                                                  fontWeight:
                                                      pw.FontWeight.bold))),
                                      pw.Padding(
                                          padding: const pw.EdgeInsets.all(4),
                                          child: pw.Text('Area of Application',
                                              style: pw.TextStyle(
                                                  fontSize: 9,
                                                  fontWeight:
                                                      pw.FontWeight.bold))),
                                      pw.Padding(
                                          padding: const pw.EdgeInsets.all(4),
                                          child: pw.Text(
                                              'Warranty Service & Product',
                                              style: pw.TextStyle(
                                                  fontSize: 9,
                                                  fontWeight:
                                                      pw.FontWeight.bold))),
                                    ]),
                                    pw.TableRow(children: [
                                      pw.Padding(
                                          padding:
                                              const pw.EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 10),
                                          child: pw.Text(
                                              'Polybound\nMagnofix\nPoliflex\nMesh\nCement',
                                              style: const pw.TextStyle(
                                                  fontSize: 12))),
                                      pw.Padding(
                                          padding:
                                              const pw.EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 10),
                                          child: pw.Text('',
                                              style: const pw.TextStyle(
                                                  fontSize: 12))),
                                      pw.Padding(
                                          padding:
                                              const pw.EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 10),
                                          child: pw.Text(
                                              client.items
                                                  .where((i) => i.enabled)
                                                  .map((i) => i.name)
                                                  .join(', '),
                                              style: const pw.TextStyle(
                                                  fontSize: 12))),
                                      pw.Padding(
                                          padding:
                                              const pw.EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 10),
                                          child: pw.Text('$durationYears Years',
                                              style: const pw.TextStyle(
                                                  fontSize: 12))),
                                    ]),
                                  ]),
                              pw.SizedBox(height: 10),
                              pw.Image(sign, width: 300),
                              pw.SizedBox(height: 15),
                              pw.Container(
                                padding: const pw.EdgeInsets.all(5),
                                color: blueColor,
                                child: pw.Text(
                                    'Standard Product & Service Warranty Statement',
                                    style: pw.TextStyle(
                                        color: PdfColors.white,
                                        fontSize: 14,
                                        fontWeight: pw.FontWeight.bold)),
                              ),
                              pw.SizedBox(height: 5),
                              pw.Text(
                                'Subject to the terms and conditions here with Authorized Franchisee of Damsure Expert Buildcare warrants that the project executed by Damsure against the following, when prepared and applied in accordance with the TDS/MOA will achieve the properties and characteristics set out in the TDS, and will retain these properties for the duration of the above listed Warranty Period.\n\nDamsure Authorized Franchisee here and after called as service warrantor offers the warranty for applying the materials accordance with the parameters defined in TDS & MOA.',
                                style:
                                    pw.TextStyle(fontSize: 10.5, color: ink700),
                                textAlign: pw.TextAlign.justify,
                              ),
                            ])))),
            // Right Panel: T&C I
            pw.Positioned(
                left: pageFormat.width / 2,
                top: 0,
                child: pw.SizedBox(
                    width: pageFormat.width / 2,
                    height: pageFormat.height,
                    child: pw.Padding(
                        padding: const pw.EdgeInsets.all(25),
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text('I. Warranty:',
                                  style: pw.TextStyle(
                                      fontSize: 14,
                                      fontWeight: pw.FontWeight.bold)),
                              pw.SizedBox(height: 5),
                              _buildListItem('1. ',
                                  'The Warranty is for the replacement of the Product of an amount equivalent to the Product cost and the labor costs for re-application of the Product due to Coating Failure in the affected portion only as may be necessary to set right the coating failure in accordance with the liabilities produced by the company.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.SizedBox(height: 5),
                              pw.Container(
                                  decoration: pw.BoxDecoration(
                                      border: pw.Border.all(
                                          style: pw.BorderStyle.dashed),
                                      borderRadius: const pw.BorderRadius.all(
                                          pw.Radius.circular(10))),
                                  padding: const pw.EdgeInsets.all(10),
                                  child: pw.Column(
                                      crossAxisAlignment:
                                          pw.CrossAxisAlignment.start,
                                      children: [
                                        pw.Text('Coating Failure',
                                            style: pw.TextStyle(
                                                fontSize: 10.5,
                                                fontWeight:
                                                    pw.FontWeight.bold)),
                                        _buildListItem('i. ',
                                            'Film integrity, flaking, peeling and blistering of the Products, caused by one coat of the Product coming off from another or the Product film coming off from the substrate.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('ii. ',
                                            'Failure of waterproofing, viz., water ingress from exteriors through the coatings in to other surface.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                      ])),
                              pw.SizedBox(height: 5),
                              _buildListItem('2. ',
                                  'The warranty will not cover Coating Failure due to factors which are beyond the control of the Company, including but not limited to:',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.Padding(
                                  padding: const pw.EdgeInsets.only(left: 10),
                                  child: pw.Column(
                                      crossAxisAlignment:
                                          pw.CrossAxisAlignment.start,
                                      children: [
                                        _buildListItem('a. ',
                                            'Structural defects, moss and other vegetative growth, excessive bird droppings/spitting, water leakage and seepage in the building structure and continuous dampness of the surface, staining due to plant pots or efflorescence and non treated area.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('b. ',
                                            'Natural calamities such as earthquakes, cyclones and flooding.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('c. ',
                                            'Failure or defects in the structure or previous coating, or any repair work undertaken or removal or tampering with any part of the treated portion.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('d. ',
                                            'Damage caused by vandalism, accidents and fire, Acts of God, abuse or negligence by the Customer, improper surface, surface with contaminants, normal wear and tear, misuse of the Products, willfully inflicted damage, exposure to chemicals, acids or fumes.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                      ])),
                              _buildListItem('3. ',
                                  'Unauthorized alterations or modifications to the waterproofing system.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('4. ',
                                  'Any physical cutting or damage to the treated layer without proper authorization will result in the voiding of the warranty.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.SizedBox(height: 10),
                              pw.Text('II. Applicability of Warranty:',
                                  style: pw.TextStyle(
                                      fontSize: 14,
                                      fontWeight: pw.FontWeight.bold)),
                              pw.Text('Warranty applies only to:',
                                  style: pw.TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: pw.FontWeight.bold)),
                              _buildListItem('1. ',
                                  'If the product is purchased directly from the company or Authorized Franchisee.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('2. ',
                                  'The end user / beneficiary of the products, ie the owner of the site where the products are applied (the "consumer").',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('3. ',
                                  'Applicable only to the slab, wall, or surface completely treated with Damsure waterproofing materials and services.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('4. ',
                                  'If the total volume of use exceeds 60 liters on a single site.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                            ])))),
          ]);
        }));

    // Spread 2: T&C II-IV (Left) + Cover (Right)
    pdf.addPage(pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (context) {
          return pw.Stack(children: [
            // Spine
            pw.Positioned(
                left: pageFormat.width / 2 - 2,
                top: 0,
                bottom: 0,
                child: pw.Container(width: 4, color: PdfColors.grey200)),
            // Left Panel: T&C II-IV
            pw.Positioned(
                left: 0,
                top: 0,
                child: pw.SizedBox(
                    width: pageFormat.width / 2,
                    height: pageFormat.height,
                    child: pw.Padding(
                        padding: const pw.EdgeInsets.all(25),
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              _buildListItem('5. ',
                                  'If a claim is reported, the company will determine the cause of the failure of the coating by inspection of the external surface subject to waterproofing.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('6. ',
                                  'Once the technical team identifies the root cause & found that it is due to product or service failure then company Authorized Franchisee will rectify the issue within 30 days.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('7. ',
                                  'All surface of the building shall be applied according to the TDS.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('8. ',
                                  'The Service Provider shall be solely responsible for the continued failure to comply with the approved applicant\'s application.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.SizedBox(height: 10),
                              pw.Text('III. Commencement and Duration',
                                  style: pw.TextStyle(
                                      fontSize: 14,
                                      fontWeight: pw.FontWeight.bold)),
                              _buildListItem('a. ',
                                  'This Warranty shall commence from the date of completion of project.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('b. ',
                                  'The Warranty shall be applicable for a specific period as detailed above, from the project completion date on all performance parameters as detailed herein. It is clarified that where any claim arises during the warranty period, the period will commence only from the project completion date of warranty even after settlement of the claim.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.SizedBox(height: 10),
                              pw.Text('IV. Exclusions',
                                  style: pw.TextStyle(
                                      fontSize: 14,
                                      fontWeight: pw.FontWeight.bold)),
                              _buildListItem('a. ',
                                  'The Products under this warranty are application based and might be affected by various external factors or combinations thereof.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('b. ',
                                  'The works which have been done as patch work with the project not included.',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              _buildListItem('c. ',
                                  'The Warranty will be void in the following events:',
                                  style: const pw.TextStyle(fontSize: 10.5)),
                              pw.Padding(
                                  padding: const pw.EdgeInsets.only(left: 10),
                                  child: pw.Column(
                                      crossAxisAlignment:
                                          pw.CrossAxisAlignment.start,
                                      children: [
                                        _buildListItem('1. ',
                                            'Water penetration due to Positive Hydrostatic Pressure, including water leakage, seeping and continuous dampness of the surface.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('2. ',
                                            'Intermittent dripping of water due to proximity of vegetation or air-conditioning units or any other sources of water leakage like potted plants, or water flow from overhead tank etc.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('3. ',
                                            'The Product is not consumed within 90 (ninety) days from the date of purchase.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('4. ',
                                            'Growth of algae or fungus on product applied surfaces due to lack of cleaning.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('5. ',
                                            'Fading and chalking as a result of use of Products in coastal areas.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('6. ',
                                            'Defects in the design of the building, including inadequate drainage system, settlement, movement or other structural defect.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('7. ',
                                            'Failure of the underlying plaster or putty coat or paint which in turn causes a failure of the coating film.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('8. ',
                                            'If coating is not applied to the entire surface as recommended.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                        _buildListItem('9. ',
                                            'Building or structural expansion or additions or reductions shifting, distortion, failure or cracking of building components.',
                                            style: const pw.TextStyle(
                                                fontSize: 10.5)),
                                      ])),
                            ])))),
            // Right Panel: Cover
            pw.Positioned(
                left: pageFormat.width / 2,
                top: 0,
                child: pw.SizedBox(
                    width: pageFormat.width / 2,
                    height: pageFormat.height,
                    child: pw.Stack(children: [
                      pw.Positioned.fill(
                          child: pw.Image(blueBg, fit: pw.BoxFit.cover)),
                      pw.Positioned.fill(
                          child: pw.Column(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                            pw.Padding(
                                padding:
                                    const pw.EdgeInsets.fromLTRB(30, 0, 30, 40),
                                child: pw.Column(
                                    crossAxisAlignment:
                                        pw.CrossAxisAlignment.start,
                                    children: [
                                      pw.Container(
                                        padding: const pw.EdgeInsets.fromLTRB(
                                            8, 16, 8, 4),
                                        color: yellowColor,
                                        child: pw.Text('Authorized Franchisee',
                                            style: pw.TextStyle(
                                                color: blueColor,
                                                fontSize: 12,
                                                fontWeight:
                                                    pw.FontWeight.bold)),
                                      ),
                                      pw.SizedBox(height: 10),
                                      pw.Row(
                                          mainAxisAlignment:
                                              pw.MainAxisAlignment.spaceBetween,
                                          children: [
                                            pw.Image(drySpotWhite, width: 80),
                                            pw.Image(damsureLogo, width: 80),
                                          ]),
                                      pw.SizedBox(height: 30),
                                      pw.Center(
                                          child: pw.Container(
                                        padding: const pw.EdgeInsets.symmetric(
                                            horizontal: 20, vertical: 5),
                                        decoration: pw.BoxDecoration(
                                          border: pw.Border.all(
                                              color: PdfColors.white, width: 2),
                                          borderRadius:
                                              const pw.BorderRadius.all(
                                                  pw.Radius.circular(20)),
                                        ),
                                        child: pw.Text('WARRANTY CARD',
                                            style: pw.TextStyle(
                                                color: yellowColor,
                                                fontSize: 26,
                                                fontWeight:
                                                    pw.FontWeight.bold)),
                                      ))
                                    ])),
                            pw.Expanded(
                              child: pw.Container(
                                padding: const pw.EdgeInsets.symmetric(
                                    horizontal: 25, vertical: 15),
                                decoration: pw.BoxDecoration(
                                  color: PdfColor.fromHex('#ffffff'),
                                ),
                                child: pw.Stack(
                                  children: [
                                    pw.Column(
                                      crossAxisAlignment:
                                          pw.CrossAxisAlignment.start,
                                      children: [
                                        pw.Container(
                                          padding:
                                              const pw.EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 2),
                                          decoration: pw.BoxDecoration(
                                            color: blueColor,
                                            borderRadius:
                                                const pw.BorderRadius.all(
                                                    pw.Radius.circular(10)),
                                          ),
                                          child: pw.Text('Customer Details:',
                                              style: pw.TextStyle(
                                                  color: PdfColors.white,
                                                  fontSize: 12,
                                                  fontWeight:
                                                      pw.FontWeight.bold)),
                                        ),
                                        pw.SizedBox(height: 10),
                                        _buildCoverDetail(
                                            'CUSTOMER NAME:', customerName),
                                        _buildCoverDetail('CUSTOMER ADDRESS:',
                                            customerAddress),
                                        _buildCoverDetail(
                                            'SITE ADDRESS:', siteAddress),
                                        _buildCoverDetail(
                                            'MOBILE NUMBER:', mobileNumber),
                                        _buildCoverDetail(
                                            'WARRANTY CARD NUMBER:',
                                            warrantyCardNumber),
                                        _buildCoverDetail('WARRANTY PROVIDER:',
                                            franchiseeName),
                                        _buildCoverDetail(
                                            'WARRANTY COMMENCEMENT DATE:',
                                            startDate
                                                .toLocal()
                                                .toString()
                                                .split(' ')[0]),
                                        _buildCoverDetail(
                                            'VALID TILL:',
                                            startDate
                                                .add(Duration(
                                                    days: 365 * durationYears))
                                                .toLocal()
                                                .toString()
                                                .split(' ')[0]),
                                        _buildCoverDetail('TOTAL AREA:',
                                            '${client.totalArea.toStringAsFixed(2)} sqft'),
                                        pw.Spacer(),
                                        _buildCoverDetail('SEAL:', ''),
                                      ],
                                    ),
                                    pw.Positioned(
                                      left: 170,
                                      bottom: -10,
                                      child: pw.Image(seal, width: 80),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            pw.Padding(
                                padding: const pw.EdgeInsets.symmetric(
                                    vertical: 20, horizontal: 30),
                                child: pw.Row(
                                    mainAxisAlignment:
                                        pw.MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        pw.CrossAxisAlignment.end,
                                    children: [
                                      pw.Column(
                                          crossAxisAlignment:
                                              pw.CrossAxisAlignment.start,
                                          children: [
                                            pw.Text('Office Address:',
                                                style: pw.TextStyle(
                                                    color: yellowColor,
                                                    fontSize: 10,
                                                    fontWeight:
                                                        pw.FontWeight.bold)),
                                            pw.Text(
                                                'Near Uppala Gate\nKasaragod',
                                                style: const pw.TextStyle(
                                                    color: PdfColors.white,
                                                    fontSize: 10)),
                                          ]),
                                      pw.Row(children: [
                                        pw.Text('PH:',
                                            style: pw.TextStyle(
                                                color: yellowColor,
                                                fontSize: 12,
                                                fontWeight:
                                                    pw.FontWeight.bold)),
                                        pw.SizedBox(width: 5),
                                        pw.Text('+91 9847 484 485',
                                            style: pw.TextStyle(
                                                color: yellowColor,
                                                fontSize: 12,
                                                fontWeight:
                                                    pw.FontWeight.bold)),
                                      ])
                                    ]))
                          ]))
                    ]))),
          ]);
        }));

    final output = await getTemporaryDirectory();
    final file = File("${output.path}/warranty_${client.remoteId}.pdf");
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  pw.Widget _buildCoverDetail(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          decoration: const pw.BoxDecoration(
              border: pw.Border(
                  bottom: pw.BorderSide(
                      color: PdfColors.black,
                      width: 1,
                      style: pw.BorderStyle(pattern: [2, 2])))),
          child: pw
              .Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(
                width: 160,
                child: pw.Text(label, style: const pw.TextStyle(fontSize: 10))),
            pw.SizedBox(width: 10),
            pw.Expanded(
                child: pw.Text(value,
                    style: pw.TextStyle(
                        fontSize: 10, fontWeight: pw.FontWeight.bold))),
          ])),
    );
  }

  pw.Widget _buildListItem(String index, String text, {pw.TextStyle? style}) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(width: 20, child: pw.Text(index, style: style)),
        pw.Expanded(
            child:
                pw.Text(text, style: style, textAlign: pw.TextAlign.justify)),
      ],
    );
  }

  Future<Uint8List> loadPdfBytes(String pdfUrl) async {
    final uri = Uri.tryParse(pdfUrl);

    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }

      throw Exception('Failed to load PDF (${response.statusCode})');
    }

    final filePath =
        uri != null && uri.scheme == 'file' ? uri.toFilePath() : pdfUrl;
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('PDF file not found');
    }

    return file.readAsBytes();
  }

  String buildPdfFileName({
    required String fallbackName,
    String? sourceUrl,
  }) {
    final uri = sourceUrl == null ? null : Uri.tryParse(sourceUrl);
    final sourceName =
        uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final rawName = sourceName.isNotEmpty ? sourceName : fallbackName;
    final sanitizedName = rawName
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    return sanitizedName.toLowerCase().endsWith('.pdf')
        ? sanitizedName
        : '$sanitizedName.pdf';
  }

  Future<File> cachePdfFile({
    required String pdfUrl,
    required String fallbackFileName,
  }) async {
    final bytes = await loadPdfBytes(pdfUrl);
    final fileName = buildPdfFileName(
      fallbackName: fallbackFileName,
      sourceUrl: pdfUrl,
    );

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);

    return file;
  }

  Future<File> generateProposalPdf(Client client) async {
    final pdf = pw.Document();
    final grandTotal = client.originalTotalPrice;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Padding(
            padding: const pw.EdgeInsets.all(24),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'DRY SPOT WATERPROOFING SOLUTIONS',
                  style: pw.TextStyle(
                      fontSize: 24, fontWeight: pw.FontWeight.bold),
                ),
                pw.Text('Contact: 9526515848',
                    style: const pw.TextStyle(fontSize: 14)),
                pw.SizedBox(height: 20),
                pw.Divider(),
                pw.SizedBox(height: 10),
                pw.Text(
                  'QUOTATION',
                  style: pw.TextStyle(
                      fontSize: 20, fontWeight: pw.FontWeight.bold),
                ),
                pw.SizedBox(height: 20),
                pw.Text(
                  'Client Details:',
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold),
                ),
                pw.SizedBox(height: 8),
                pw.Text('Name: ${client.name}'),
                if (client.phone != null && client.phone!.isNotEmpty)
                  pw.Text('Phone: ${client.phone}'),
                if (client.address != null && client.address!.isNotEmpty)
                  pw.Text('Address: ${client.address}'),
                pw.SizedBox(height: 32),
                pw.Divider(),
                pw.SizedBox(height: 16),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Total Area:',
                      style: pw.TextStyle(
                          fontSize: 16, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(
                      '${client.totalArea.toStringAsFixed(1)} sqft',
                      style: const pw.TextStyle(fontSize: 16),
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Grand Total:',
                      style: pw.TextStyle(
                          fontSize: 16, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(
                      'Rs. ${grandTotal.toStringAsFixed(1)}',
                      style: const pw.TextStyle(fontSize: 16),
                    ),
                  ],
                ),
                if (client.discountedPrice != null &&
                    client.discountedPrice! < grandTotal) ...[
                  pw.SizedBox(height: 8),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Discounted Amount:',
                        style: const pw.TextStyle(
                            fontSize: 16, color: PdfColors.green),
                      ),
                      pw.Text(
                        'Rs. ${(grandTotal - client.discountedPrice!).toStringAsFixed(1)}',
                        style: const pw.TextStyle(
                            fontSize: 16, color: PdfColors.green),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 16),
                  pw.Divider(),
                  pw.SizedBox(height: 16),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Final Amount to Pay:',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.Text(
                        'Rs. ${client.discountedPrice!.toStringAsFixed(1)}',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold),
                      ),
                    ],
                  ),
                ] else ...[
                  pw.SizedBox(height: 16),
                  pw.Divider(),
                  pw.SizedBox(height: 16),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Final Amount to Pay:',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.Text(
                        'Rs. ${grandTotal.toStringAsFixed(1)}',
                        style: pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold),
                      ),
                    ],
                  ),
                ],
                pw.Spacer(),
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    'Generated on: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    final output = await getTemporaryDirectory();
    final file = File("${output.path}/proposal_${client.remoteId}.pdf");
    await file.writeAsBytes(await pdf.save());
    return file;
  }
}
