import 'dart:io';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import '../models/client.dart';

class PdfService {
  Future<File> generateWarrantyPdf(Client client, DateTime startDate, int durationYears) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(level: 0, child: pw.Text('Damsure Warranty Certificate')),
              pw.SizedBox(height: 20),
              pw.Text('Client Name: ${client.name}'),
              pw.Text('Address: ${client.address ?? 'N/A'}'),
              pw.Text('Email: ${client.email ?? 'N/A'}'),
              pw.SizedBox(height: 20),
              pw.Text('Warranty Details:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.Text('Start Date: ${startDate.toLocal().toString().split(' ')[0]}'),
              pw.Text('Duration: $durationYears years'),
              pw.SizedBox(height: 20),
              pw.Text('Project Measurements:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              ...client.items.where((i) => i.enabled).map((item) {
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Item: ${item.name}'),
                    pw.Text('  Area: ${item.area.toStringAsFixed(2)} sqft'),
                    pw.Text('  Price: Rs.${item.totalPrice.toStringAsFixed(2)}'),
                  ],
                );
              }),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Text('Total Area: ${client.totalArea.toStringAsFixed(2)} sqft'),
              pw.Text('Total Price: Rs.${client.originalTotalPrice.toStringAsFixed(2)}'),
            ],
          );
        },
      ),
    );

    final output = await getTemporaryDirectory();
    final file = File("${output.path}/warranty_${client.remoteId}.pdf");
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  Future<File> generateProposalPdf(Client client) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(level: 0, child: pw.Text('Project Proposal')),
              pw.SizedBox(height: 20),
              pw.Text('Client Name: ${client.name}'),
              pw.Text('Address: ${client.address ?? 'N/A'}'),
              pw.Text('Phone: ${client.phone ?? 'N/A'}'),
              pw.SizedBox(height: 20),
              pw.Header(level: 1, child: pw.Text('Measurement Details')),
              pw.SizedBox(height: 10),
              ...client.items.where((i) => i.enabled && i.deletedAt == null).map((item) {
                return pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 10),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Item: ${item.name}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      pw.Bullet(text: 'Area: ${item.area.toStringAsFixed(2)} sqft'),
                      pw.Bullet(text: 'Rate: Rs.${item.price.toStringAsFixed(2)} / sqft'),
                      pw.Bullet(text: 'Item Total: Rs.${item.totalPrice.toStringAsFixed(2)}'),
                    ],
                  ),
                );
              }),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Area:'),
                  pw.Text('${client.totalArea.toStringAsFixed(2)} sqft'),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Original Total Price:'),
                  pw.Text('Rs.${client.originalTotalPrice.toStringAsFixed(2)}'),
                ],
              ),
              if (client.discountedPrice != null) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Discount Amount:'),
                    pw.Text('Rs.${client.discountAmount.toStringAsFixed(2)} (${client.discountPercentage.toStringAsFixed(1)}%)'),
                  ],
                ),
                pw.SizedBox(height: 5),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Final Price:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                    pw.Text('Rs.${client.finalTotalPrice.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                  ],
                ),
              ],
            ],
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
