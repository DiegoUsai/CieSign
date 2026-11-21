package io.github.diegousai.ciesign.tools;

import eu.europa.esig.dss.enumerations.Indication;
import eu.europa.esig.dss.enumerations.SignatureLevel;
import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.model.x509.CertificateToken;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.spi.DSSUtils;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.CommonTrustedCertificateSource;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import eu.europa.esig.dss.validation.reports.Reports;

import java.io.File;

/**
 * Valida i file indicati con EU DSS, usando come radice fidata il certificato
 * di prova. Esce con codice 1 se una firma non è integra o non è di livello
 * BASELINE-B.
 *
 * Uso: mvn -q compile exec:java -Dexec.args="certificato.der file1 file2 ..."
 */
public final class DssValidator {
    public static void main(String[] args) throws Exception {
        CertificateToken trusted = DSSUtils.loadCertificate(new File(args[0]));
        CommonTrustedCertificateSource source = new CommonTrustedCertificateSource();
        source.addCertificate(trusted);
        CommonCertificateVerifier verifier = new CommonCertificateVerifier();
        verifier.setTrustedCertSources(source);
        verifier.setAIASource(null);
        verifier.setOcspSource(null);
        verifier.setCrlSource(null);

        boolean ok = true;
        for (int i = 1; i < args.length; i++) {
            SignedDocumentValidator v = SignedDocumentValidator.fromDocument(new FileDocument(args[i]));
            v.setCertificateVerifier(verifier);
            Reports reports = v.validateDocument();
            SimpleReport r = reports.getSimpleReport();
            for (String id : r.getSignatureIdList()) {
                SignatureLevel level = r.getSignatureFormat(id);
                Indication ind = r.getIndication(id);
                boolean intact = reports.getDiagnosticData().isBLevelTechnicallyValid(id);
                boolean baselineB = level != null && level.name().endsWith("BASELINE_B");
                System.out.printf("%s  %s  formato=%s  integra=%s  indicazione=%s %s%n",
                        new File(args[i]).getName(), id.substring(0, 12), level, intact, ind,
                        r.getSubIndication(id) == null ? "" : r.getSubIndication(id));
                if (!intact || !baselineB) ok = false;
            }
        }
        System.exit(ok ? 0 : 1);
    }
}
