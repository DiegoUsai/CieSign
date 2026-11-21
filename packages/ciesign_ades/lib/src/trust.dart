import 'dart:convert';
import 'dart:typed_data';

import 'x509.dart';

/// Esito del controllo della catena di certificazione di un firmatario.
enum ChainStatus {
  /// Catena valida fino a una radice CIE del Ministero dell'Interno e
  /// certificato valido alla data della firma.
  cie,

  /// Catena CIE valida ma certificato fuori validità alla data della firma.
  cieExpired,

  /// Emittente sconosciuto: non è una CA della CIE (per esempio un
  /// certificato di firma digitale di un prestatore qualificato).
  unknownIssuer,

  /// Un anello della catena ha una firma non valida.
  brokenChain,
}

/// Catena del firmatario, dal suo certificato fino alla radice.
class ChainReport {
  ChainReport(this.status, this.path, {this.signerAllowsSignature = true});

  final ChainStatus status;
  final List<Certificate> path;

  /// KeyUsage del firmatario con digitalSignature.
  final bool signerAllowsSignature;

  /// Firma elettronica avanzata con la CIE: catena CIE valida alla data della
  /// firma e chiave abilitata alla firma.
  bool get isCieFea => status == ChainStatus.cie && signerAllowsSignature;

  String get label => switch (status) {
    ChainStatus.cie when signerAllowsSignature => 'Firma elettronica avanzata con CIE',
    ChainStatus.cie => 'Certificato CIE non abilitato alla firma',
    ChainStatus.cieExpired => 'Certificato CIE non valido alla data della firma',
    ChainStatus.unknownIssuer => 'Emittente non riconosciuto come CA della CIE',
    ChainStatus.brokenChain => 'Catena di certificazione non valida',
  };

  String? get note => isCieFea
      ? 'Certificato emesso dal Ministero dell\'Interno. Aruba Sign, Dike e programmi simili mostrano questa firma '
            'come non qualificata: è normale, perché la CIE produce una firma elettronica avanzata (FEA) e non una '
            'firma digitale qualificata.'
      : null;
}

/// Certificati pubblici delle CA della CIE (Ministero dell'Interno), dalla
/// pagina ufficiale https://www.cartaidentita.interno.gov.it/pa-e-imprese/certification-autority-2/ .
/// Le impronte SHA-256 coincidono con quelle pubblicate da tre fonti
/// indipendenti e le due radici con l'elenco di fiducia di AgID (TSL-IT).
/// Lo stato di revoca (OCSP o CRL) non è controllato qui.
class CieTrust {
  // National root CA, 2016-2036. SHA-256 87364FB476E74962E7C495B9BBAF727813EE007CB56A0ADA6AB9868123DB267E
  static const _root2016 =
    'MIIG4DCCBMigAwIBAgIIRmop7bWMajUwDQYJKoZIhvcNAQELBQAwgasxQjBABgNVBAMMOU5hdGlvbmFsIHJvb3QgQ0EgZm9yIHRo'
    'ZSBJdGFsaWFuIEVsZWN0cm9uaWMgSWRlbnRpdHkgQ2FyZDE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERl'
    'bW9ncmFmaWNpIC0gQ05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwHhcNMTYwNjA2MTQz'
    'NzI0WhcNMzYwNjA2MTQzNzI0WjCBqzFCMEAGA1UEAww5TmF0aW9uYWwgcm9vdCBDQSBmb3IgdGhlIEl0YWxpYW4gRWxlY3Ryb25p'
    'YyBJZGVudGl0eSBDYXJkMTcwNQYDVQQLDC5EaXJlei4gQ2VudHIuIHBlciBpIFNlcnZpemkgRGVtb2dyYWZpY2kgLSBDTlNEMR8w'
    'HQYDVQQKDBZNaW5pc3Rlcm8gZGVsbCdJbnRlcm5vMQswCQYDVQQGEwJJVDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB'
    'AMKQoMWIoz5V+cTvVu+rAU4GXsrhCHBGSiPluVwEDwrLa4VmUYcBpKV8bJMmSelbjE8TGtCvIdb3HmrK72ts/9cKIJItgMLEH4DW'
    'IO72F1EW4oYFZ7V4QalK3x5AIk6YCIw+PLYiv+i/C/7z+OwMeOyaPDayPK7bwwBloJHS/IwHy1eQLqZ58zyCNyjBAmtWQgqP6rLT'
    'FG44hRk6jCsHSBuMSe36qs21ZaA3qruitRVL2BMIe1+VnudwI+XWhrTaoa5UuZJygE52w7xbGmpv+Q6TapjVPc7s/l7aLBAvlo/K'
    'W3zDWZ8Joj0qftAFWCRI+Qbuw8GR6lvkp7vm85ymUd9nS/Izo0iEsDyppED/CuG0+n+y7CfGlZ6PqKM0WOeG856oH/BbuMrhPZ68'
    'w2S/0tgLFWcOLwFkBJubVTFW5sWrYmgpxtdjj+8fpFmxstPXOA3DOt6NTEUOeT2xFYn323FpsQm+LV6tTzUcl/T2ud9dw0ede5uc'
    'xI6caLR3MvaChqErUyZF0F09x3sKkedP8tHNutsvEjtgnkhTlypGFh+clAPFPJlwTFkp9VB2ULa7giOq8+iEqj7LApB1tp/vgR1q'
    'AxTNhWTJpegdrfjFvLO+ApY0a6NNxKjXe19pPx32YWuGcGOp8At1KRTvBrW1qWlrUn6j99SDcTHjEwmV54nHAgMBAAGjggEEMIIB'
    'ADAdBgNVHQ4EFgQUR8qRudhBHPfA4cUWUD454S+L8jUwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRHypG52EEc98DhxRZQ'
    'PjnhL4vyNTBeBgNVHSAEVzBVMFMGBCtMLwEwSzBJBggrBgEFBQcCARY9aHR0cDovL3d3dy5jYXJ0YWlkZW50aXRhLmludGVybm8u'
    'Z292Lml0L3BvbGljeS9yb290Y2FfY3BzLnBkZjA9BgNVHR8ENjA0MDKgMKAuhixodHRwOi8vbGRhcC5jaWUuaW50ZXJuby5nb3Yu'
    'aXQvY2llcm9vdGNhLmNybDAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBAHzFm/7B4+D1bJWUM38mL2UD6SNr11RV'
    'm9ohHPx586rb9tDiea7wgTWBBLyZWpdbDWQfSU+13kSsMUvZH60Fg/A95WKrIGo29fjFdHkJrrJm0Tc9CcMLLULWyQByoJAv/01N'
    'YykGzdgyAJbdkvWTihhlZBpFZ2GMQT4g099Xd6iWXiEaKcDDMh9o8PU0fZy0L274HE6ql5P5xdiqfv3dyiEM+eZ5OEMKOkkJPtlX'
    'X/H20g0AkUZpFlfqC6mhuEad28YH3OlTJyl7sEYNPqjEp9UvcdD9XpAVr/GxGHf96H4Ozqu9ZQFCG6E5aMMYXOxhXHNnRpnwkao1'
    'edaomxJTDtcDSdFE7Bp0fKRUpSVUpLbYcAda0/kgl7s/bZQlxZKNhSqOZuQA91LKYB3CwXEHblJP9j45Em86J0rwfpB28Cb9ePNC'
    'kHaoSkJ25PtKzNgKtikkGZCMmYpdiyQELuoBZHtxJ+Jo3tmc6Wy9WF9FzPYyKrC1d+NJdF8477zCpXk8l5z5zDoFt5H30Xdz9x+t'
    'oehpemDABBvbNd+jSfwpay6O7qr8cnr7O+9uBrzKYv5yjgxBQ7KVF367aEXYdplSzJzlj+dl/sqHzyeTcw7CaMptYy5XW9Jbmkva'
    'xWX2vK8/rpnLv9Y9hX1KmmFMAK3PXgTw8Bym3+nM8Qc76Sx/LOHL';

  // National root CA, 2024-2044. SHA-256 40F425927E8A1E6A297A15C2A9D79E2221BF4FE25B2F21E3BFAD53A1BA58B0D7
  static const _root2024 =
    'MIIG4DCCBMigAwIBAgIIdx9NUGFhnMowDQYJKoZIhvcNAQELBQAwgasxQjBABgNVBAMMOU5hdGlvbmFsIHJvb3QgQ0EgZm9yIHRo'
    'ZSBJdGFsaWFuIEVsZWN0cm9uaWMgSWRlbnRpdHkgQ2FyZDE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERl'
    'bW9ncmFmaWNpIC0gQ05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwHhcNMjQwNTE2MTM1'
    'NTEyWhcNNDQwNTE2MTM1NTEyWjCBqzFCMEAGA1UEAww5TmF0aW9uYWwgcm9vdCBDQSBmb3IgdGhlIEl0YWxpYW4gRWxlY3Ryb25p'
    'YyBJZGVudGl0eSBDYXJkMTcwNQYDVQQLDC5EaXJlei4gQ2VudHIuIHBlciBpIFNlcnZpemkgRGVtb2dyYWZpY2kgLSBDTlNEMR8w'
    'HQYDVQQKDBZNaW5pc3Rlcm8gZGVsbCdJbnRlcm5vMQswCQYDVQQGEwJJVDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB'
    'AOJjzSc1shYOe3qe5+m4AKk40tbBjck1jlXXEu+pT/8DdcAuYjJAccgPXo+IDk/X8HpLcqJpwg+Ep0FSg7F0/+uD1qQWKHKPHpNb'
    '35LrNbwcl4ANk4lBNeV7klxFBn7IKOfRjC0xcxe+IrW2fT8BzJ7PWLzTUtLUm85uCBgPWjWpazUTTTMrq6Wm5q/4A7G+P1CqibP2'
    'gBlWZzyYe7sG6S2LTX3aQH+TLMGViXPDfvTsUTo0JZeaOqlOiL3wU7zOLE2u3bn+4GURFsVj8OAIrbDr9oFdXCNobStDUOlwtafu'
    'cpBAqVNClLCQPuxVyuGbyju+mvGarA4ka7Lg6diRMt6h6qyRjZRKQTTzA/RtOf0OKKZ2OW9wG5dwwVKsERxatGq+fCdpKzyVL128'
    'NJl0snS9c6hyxQjn85nxudwUF8ru78VghX5Q93SfbB2qTeFsaNPh1rtSSYv+uW8DspLWO9Mk+Xndqt4k/U3G/DfPBWrg1wqjuOdP'
    'GqY3/pFaveIwTCsHwvBV+eLfIt5TJxw7SC91B36bmfsVISJLJAr3KnUD64U9bPU5yyCR6r8V6pncMT6Y1rWBaVNOJK/NIgHyakv6'
    'o9psDgrl6qcCLa7wt+KA7Ny0D6+8mi1JjthC/kpfJZEYDD5lM11SFVlJ2Bn5gZmg+OCa+9Wfu7aCxOXyTuUnAgMBAAGjggEEMIIB'
    'ADAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFEdvJRrD1fP+XjSTEp/YgRXcUgxPMF4GA1UdIARXMFUwUwYEK0wvATBLMEkG'
    'CCsGAQUFBwIBFj1odHRwOi8vd3d3LmNhcnRhaWRlbnRpdGEuaW50ZXJuby5nb3YuaXQvcG9saWN5L3Jvb3RjYV9jcHMucGRmMD0G'
    'A1UdHwQ2MDQwMqAwoC6GLGh0dHA6Ly9sZGFwLmNpZS5pbnRlcm5vLmdvdi5pdC9jaWVyb290Y2EuY3JsMB0GA1UdDgQWBBRHbyUa'
    'w9Xz/l40kxKf2IEV3FIMTzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBAEzG0DyzJTVzv9XKZRnrPEKqqEMOoto/'
    'zD0P6x7Qn2/8cgYfOzNr1mor0bVouRjr4+xevzIHNLCB8auclA4mmMPs4yWRu762fIvhdwP6csBzTs2WoSXM/IqRVqDS8cQDuRks'
    'Cg/eRXNDzoqPC8kN/7fId/DQkLGOVP6nlf/PNpDDh8RE93HWc9/wT6CuYnTzVTLUBlbvku5Z4Uam3LJMqsFe5y9kXau01n6R1voA'
    'WJGERI8kJZJ/r3kAn4rRqDQ2lOpRMb8CImK+c3S28C0ZT6umsjsUfAscgTVLLTvPVp4aJJ63UoofW8g1pbFAqxTATF7XRZpHAHYR'
    'yDJleK10ci8xwTImw/kyhzxpcy330jTJryXE4Bza7wP+nvmrvNPoE20TiBlkwtDR3Eexego9bTo6pyW5oofkZ84IO8Y9AnQwZ3wX'
    'D+CMY3n5TveoNFF6PCQNggUCeKLtE94Au3sNntJFL7FwJ6kr3XnetpiD7H9rR3Md62HURlnI/mqH17609jtechIE8vLPAQcQ9VBe'
    'x0aGJDsB4VX4QWAiPzsFl+5aiJgoSKhRr3trYz0Re1eyAFkAwh6rXumc330D5Vh+Ofj9rsNwtsR1AicwSEfmD40LHnolX3CJMF1R'
    'TUXZb0ooBiuTw8GEQoVmJxVJOw9+kDcFss1YdtR8SuOamYYxd4MV';

  // SUBCA1, 2016-2031. SHA-256 B1A742662B31738726071132840880C251F63D47DB6B60A6DC6A8333EB1706AE
  static const _subca1 =
    'MIIG7jCCBNagAwIBAgIIRs2LVrWtjRswDQYJKoZIhvcNAQELBQAwgasxQjBABgNVBAMMOU5hdGlvbmFsIHJvb3QgQ0EgZm9yIHRo'
    'ZSBJdGFsaWFuIEVsZWN0cm9uaWMgSWRlbnRpdHkgQ2FyZDE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERl'
    'bW9ncmFmaWNpIC0gQ05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwHhcNMTYwNjA2MTYx'
    'NjQxWhcNMzEwNjAzMTYxNjQxWjCBsjFJMEcGA1UEAwxASXNzdWluZyBzdWIgQ0EgZm9yIHRoZSBJdGFsaWFuIEVsZWN0cm9uaWMg'
    'SWRlbnRpdHkgQ2FyZCAtIFNVQkNBMTE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERlbW9ncmFmaWNpIC0g'
    'Q05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw'
    'ggIKAoICAQC3Sk0E2bwMzrp2oRZ52be8Z37f8osuLwKHt4PTysD+lHyGi3/P37omXUzZewZ/SuSkDY0LzgloMjqiZdfVvobQ/rN+'
    'ICwgcfB6Kf2fFPqN1mPTeJLI537kemkN/qwHIZO+HOlmklY+nJ/HrlVQJ6dxrfd8hWLpXR4L2yTtqhB2bMrZGN+EtsiML8DetRM/'
    'i4/AV5UYTOrWEbexnKgwwATu9TgDSk+flqwB6R24islNbfDlnmm+XXaaba3Jflajk5vAt8cYyVkYx6QCwVDbifHWEG52z7GWXD/T'
    'kDIV2FPm6qTCQdBPfEbmXfTpIcu8sN+gIQMlb/fbcsqi9liw26pxO4RlvO7K74GbcTgUY4q7iG+SzNkXXLXRDlLsjloA+y3j/TPM'
    '0RwBSsnYghDrcxyq8KXNuKk6JXtv5N68Qttr+SVYhE3EvMUeUJqgp1s1siDKswcuIasl07HlcgYZVC6joEg9xlEXIcCMFibyNIjr'
    'm+oybA1srZ9lqf+14Z9ERGacJJTGy3Mkl7UxWNBeyK3DT15j8pZYwVIvJBfNX8x+r59huVQCOqxwvCe2AHIAqPkuLSjqVFFek8q6'
    'l2az3mcY2mgE8AvuDu6rilJEq2ZU3sGBM3ep7yuKZErwlU0sXlqxMvoDe44/rU8Puan+4/OI9+VDaHi4P6RxTTcU4DkQfwIDAQAB'
    'o4IBCzCCAQcwHQYDVR0OBBYEFOJDidPiBHX9JjL5SkxB3NmJPuTBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUR8qR'
    'udhBHPfA4cUWUD454S+L8jUwYgYDVR0gBFswWTBXBgQrTC8CME8wTQYIKwYBBQUHAgEWQWh0dHA6Ly93d3cuY2FydGFpZGVudGl0'
    'YS5pbnRlcm5vLmdvdi5pdC9wb2xpY3kvc3ViY2FfYXV0aF9jcHMucGRmMD0GA1UdHwQ2MDQwMqAwoC6GLGh0dHA6Ly9sZGFwLmNp'
    'ZS5pbnRlcm5vLmdvdi5pdC9jaWVzdWJjYTEuY3JsMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAD+TJp+WNJQFf'
    'yCzlmPKNXsUTHiARHgLp5u08Rm5jDO1ffSp3YAWQ0u4BIy5HzCRxnQReJcDe3sR+dxnAh+6DW69pu5zxJkBNhgw+J7mGizyQ7moH'
    'xMZeYGMgKSGzHOQp84OA7vb2km4J8U90iJIEbfWo1o0qrFoFlyW/Xstswevyy7/G6uGccomwuJS/oklw1Jx8jIxAD+4KPfhg7MEO'
    '1Ae8CJ2i4bQdK+oRpCMHMxog23C9Ry3AqNRyQDn4HQ7gk2MgxlOjxfdrYE6u1YtV2mliBoOVmI6U10BzsqK5mKbj+mNVG0wTTNlI'
    'beqqQsnGqA2D2XA/l0p8gGG0dnjK+Y1bishGX9nI6c868r24WYu1Xjw2XgjFeJzyL78iOVDxyewRjpgZhEuIo/DPyW/SkMH4JkvA'
    'Ba/CmNIe3EuaE1/SkXMePWG73ZOmh4cytQ8yyMNviUqU274EQMhtWx3XFvfDB0eu+E9u3S5dqVaanArroE60WFp/Bl2dNDHJgis3'
    'CewlZLbCRxc4rH0g8Ipfqe0Wte9uvhLZhColvbZ/SEXCp2yUzFp3UYmsmRxyVlcFGwDF4/6ZXXhsrWTH/0jV8Or9zV598Tv7Lo5g'
    'z7IA+GI2BpZd96tz2+ItNxLdRl0ZVavpJYeL/6dQ/OyHUnGJrSJUq/3BKLtOgMTmEOpXRUE=';

  // SUBCA002, 2020-2035. SHA-256 363A3386E9016ECBAFA3D11BE2877540812B52D6839E71DD22AB98D8A734CA05
  static const _subca002 =
    'MIIG8DCCBNigAwIBAgIIbidwj1LWzEAwDQYJKoZIhvcNAQELBQAwgasxQjBABgNVBAMMOU5hdGlvbmFsIHJvb3QgQ0EgZm9yIHRo'
    'ZSBJdGFsaWFuIEVsZWN0cm9uaWMgSWRlbnRpdHkgQ2FyZDE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERl'
    'bW9ncmFmaWNpIC0gQ05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwHhcNMjAwNTI1MDYx'
    'NDMyWhcNMzUwNTIyMDYxNDMyWjCBtDFLMEkGA1UEAwxCSXNzdWluZyBzdWIgQ0EgZm9yIHRoZSBJdGFsaWFuIEVsZWN0cm9uaWMg'
    'SWRlbnRpdHkgQ2FyZCAtIFNVQkNBMDAyMTcwNQYDVQQLDC5EaXJlei4gQ2VudHIuIHBlciBpIFNlcnZpemkgRGVtb2dyYWZpY2kg'
    'LSBDTlNEMR8wHQYDVQQKDBZNaW5pc3Rlcm8gZGVsbCdJbnRlcm5vMQswCQYDVQQGEwJJVDCCAiIwDQYJKoZIhvcNAQEBBQADggIP'
    'ADCCAgoCggIBAJl0P3lxsxXbmvW/i6b4HOrzEzSwmkmjhWcCgm8zykHw5Zm9yA8ex3fhsPTQaw/to1T2183kapcg/lnXnR2Rx5v3'
    'VvvRJODs6kMzWIQ/elJjguitlsPrjmjgsIXYBI+Re8ITHP0J783jHhWM7kbhJ8XAjk39mhX/NFx6mLgOBqdep/QAkldV8s2EApod'
    'clvdB42QfrkPd3yWZmo7jP5Jp5QJ5LmsThWXCmXKCPcAiXY1Z/NFWK32DmjrabBRJm2YyvOsXQVjiyjYjowwVIG0UeF0ZGBCF0Wd'
    '7jjIghyivTi/hMWXOy++XsfmgCS5GD6ylnsSP+vJXmOFS6aINkTpUlfYHw35VRU9RFIt9qunKaLJA+BgvHZxGLcfhe6mveLalunC'
    'H7KLip0oVDO5qw2/ct5kX/PlcDlGI97eWWI2EsHmaHeHns++n1RuRRpmHlF5cb92dF3ciFKgmkVKK3xHlG+j0++AusJMKOSJZl2n'
    '8vL2YzeCWWcbidZeze/q5Mq0H+snRTKq9dnjfwln+81Fvh9GjtWviDgJ/Trd6CRrMEUhbCi3drpVvYTT2na9HVikLD44CurZgcOY'
    'CaPlf47hjKQwNT0dBtvZdF6ThwJz9HFOTMHUTiaXD4vEC6kLRnAA1nL7ticLN7MfRECMK+/8c8hgHUe5RB1DXiYfTus2WOGzAgMB'
    'AAGjggELMIIBBzAdBgNVHQ4EFgQU+S7pCGSforgrqDKVQXPpfZ0MFRgwEgYDVR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBRH'
    'ypG52EEc98DhxRZQPjnhL4vyNTBiBgNVHSAEWzBZMFcGBCtMLwIwTzBNBggrBgEFBQcCARZBaHR0cDovL3d3dy5jYXJ0YWlkZW50'
    'aXRhLmludGVybm8uZ292Lml0L3BvbGljeS9zdWJjYV9hdXRoX2Nwcy5wZGYwPQYDVR0fBDYwNDAyoDCgLoYsaHR0cDovL2xkYXAu'
    'Y2llLmludGVybm8uZ292Lml0L2NpZXJvb3RjYS5jcmwwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUAA4ICAQBVmLny00jZ'
    'q9Zop2SfljcgUtZ2WAZVUcI1tsXbNRKsarhgqg1G3HKv9jufqxYoL+gfAOa5jRoPmqvWGuSBzM9fSMu8bURDdSljoTos4OR+8hgE'
    'Yz4NoDTHqyXxXgwGVcGRSz8jppFUQOFur9yScx+mGY1XPGiO3FBDwROu2jhIT3eFBbTq0369lP2GI+qAgIkeoggjwR1u1WNasoCD'
    'eLViDOrWvSOB3/FPQIhGVWhsJnIGq8zJQGfuo/P8ae33CleB69aZIsR3TuPQ17tWg5zG6Zbq7f/9p02pTm6Erj0TLtPJqMoPLloW'
    '/LmO5EfB9BcTYT187vogjZ3M/ulrSM/Zm4bb3zHgPBNRY0Nl27Mw7E9swaCXeIJySLGv/aS4o4cNqkFDJH5btrDrShQBGD9ANi77'
    'LlSlEQ4FmzY1X4UZk5enWQ1A/uOylLrtfG3puXcekdcxTneCdkbAr+yo83Pzba/ZX7kec/tmnoL8QfPFAbrQx2wnxK9AmxQmvxwA'
    'm9GmkRIe8TFgAWODIPiA/rRMVI2TvI37xGWWFZNOxkgPY5uSajZuOArTrjDUGHqalKQSksylIZ65i4sUXsHGNyH0OFt7ZYAfC0YI'
    'l+f62yF2MwtqVv7bZB/GF7vb1JZGj9hqTUGVRjz0MFruMBsMhhAUUykCTegIq5C/MFcCaJQEPQ==';

  // SUBCA003, 2024-2039. SHA-256 8F3CCE1555F96594D294F00FEC381FDA9D8BAC7271FCBDC8BB8F7766B0E27EEE
  static const _subca003 =
    'MIIG8DCCBNigAwIBAgIIJJZNjbfc1rcwDQYJKoZIhvcNAQELBQAwgasxQjBABgNVBAMMOU5hdGlvbmFsIHJvb3QgQ0EgZm9yIHRo'
    'ZSBJdGFsaWFuIEVsZWN0cm9uaWMgSWRlbnRpdHkgQ2FyZDE3MDUGA1UECwwuRGlyZXouIENlbnRyLiBwZXIgaSBTZXJ2aXppIERl'
    'bW9ncmFmaWNpIC0gQ05TRDEfMB0GA1UECgwWTWluaXN0ZXJvIGRlbGwnSW50ZXJubzELMAkGA1UEBhMCSVQwHhcNMjQwNTE2MTQw'
    'MzM3WhcNMzkwNTEzMTQwMzM3WjCBtDFLMEkGA1UEAwxCSXNzdWluZyBzdWIgQ0EgZm9yIHRoZSBJdGFsaWFuIEVsZWN0cm9uaWMg'
    'SWRlbnRpdHkgQ2FyZCAtIFNVQkNBMDAzMTcwNQYDVQQLDC5EaXJlei4gQ2VudHIuIHBlciBpIFNlcnZpemkgRGVtb2dyYWZpY2kg'
    'LSBDTlNEMR8wHQYDVQQKDBZNaW5pc3Rlcm8gZGVsbCdJbnRlcm5vMQswCQYDVQQGEwJJVDCCAiIwDQYJKoZIhvcNAQEBBQADggIP'
    'ADCCAgoCggIBAM+DgWkGOnWDMPtesNeqhW62p2chjnx181XY1iJ88rYVQj9ptLGFibURGbAFaSJ1uCniSxrMPByliDkadHkxMjTr'
    '+9teZu3kPnOoV2pgR78Tn8RLG8BnruX4riuaP1vyKKVFEoO7Td7a075v6i0ipYyZtZ0twrtpAD2ZQbrTdUCy3HuWdn0CD7q3YDGs'
    'kIYfIbFI1R3zgpxM4wSbCO5bqSxiyk2iMDbm/cQ/b0eX8shXdNhNPrN/imR4w1rZwzSp0JNH1Madf3D9YdAUDUTCQG405lVL4ha0'
    'pUlG+g0Ig0BHDLxBAO6iZ7CZY+YcgV945FqosiBrH1Y8PFmN1VBlFKn351hZOAfgnLj1Y6gGgLz2+WUNWZpGDfdPhODWhmffqzeT'
    'GihuOgIzfQG3wL1uQ6aeTqQkcDECs/Tll6lQW6WVqUdFGw8h4hHKHdAizTDi+/vYlGYUceuNCYM+woE+Omvwo8+1BcqFpVO0YAxl'
    'mzVl/HN8kRvoaiwIy6XH5GON0I8aPSFsCqXl0tou8llpdueI6R33COn6r7O3VjQNXJEpUesHpi9vTuIPaP9W4OCRO9wjrIot6Qtm'
    'QKTpoN0tpdDsMLdQ5//zdRG8D4qz3dH0kFEqr5li1rXOUnK79SAygYkdLuD7PRFUyUkVuAbMrn/snLAGLaUpx0FtcpzQHQojAgMB'
    'AAGjggELMIIBBzASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFEdvJRrD1fP+XjSTEp/YgRXcUgxPMGIGA1UdIARbMFkw'
    'VwYEK0wvAjBPME0GCCsGAQUFBwIBFkFodHRwOi8vd3d3LmNhcnRhaWRlbnRpdGEuaW50ZXJuby5nb3YuaXQvcG9saWN5L3N1YmNh'
    'X2F1dGhfY3BzLnBkZjA9BgNVHR8ENjA0MDKgMKAuhixodHRwOi8vbGRhcC5jaWUuaW50ZXJuby5nb3YuaXQvY2llcm9vdGNhLmNy'
    'bDAdBgNVHQ4EFgQU+LbUqPVMY/CaGMSqUumS65tDx+EwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUAA4ICAQBsWaBdJkl1'
    'YU217X4HChaW3PYV0ocii+MFkTwxDmAKqGXTEWbPZSz00NyHDORMKY/cx0s3eNZ14caed/KBbdgkEfl3Wymq9mWSWnjIbB39d4L1'
    'XalZWOquA6iQMrM3+9Aa/cOwj63rxYeDHjDRwW5OETSk47WTdJoMU3c21kbXUSlIX3VgW+8pX5KDEMwQobuIyS2TUpc10DV2MbDD'
    'ZFeaUePVXD+xuBkCJ4LR6yXsWdad8NPRX0SK/dtOB0DSdPM7HpNMeurNF6KdxHK3w5rbt0n8n129NmPT4lnxAw1U0wZULU29gu9W'
    'hadlwbSLxvXSfsh4dLLwyLL4PwjBgIYYGkLt9n/JQD5XF2BM94LOpdv5VBa6nhaCralW9npc1djK02CgINROFR+rwFhaWPptYZmn'
    'MVX0Pw9Qe8X+Nrml576sJydJCh+Obc/auwbpjW9oTibvdqTeYAk7DGyitOSI3GZSQEccfaWxxcL2t6hYmMXswMLrG8THL++8D7fB'
    'o01kV5V2sdhJ2NdFeKvylGfQBU6kmAGtEkq5EElz3UhfArjj7d31FBPM6TKEmmMi5vJJ1IqyjxIHfHtRnRFjQadPxjf2Zdo3nsgC'
    'vL/5HjcTFIj2d6ZJIrUMBLX/q/aQRsaEZciEWUDZV9LCfnmEmgPd3YEr5Lqqxt+9Ej7Rt+VL1w==';

  static Certificate _c(String b64) => Certificate.fromDer(Uint8List.fromList(base64.decode(b64)));

  static final List<Certificate> roots = [_c(_root2016), _c(_root2024)];
  static final List<Certificate> intermediates = [_c(_subca1), _c(_subca002), _c(_subca003)];

  /// CA intermedia della CIE che ha emesso [signer], da inserire nella firma
  /// perché gli altri programmi possano ricostruire la catena.
  static Certificate? intermediateFor(Certificate signer) {
    for (final ca in intermediates) {
      if (signer.isIssuedBy(ca)) return ca;
    }
    return null;
  }

  /// Costruisce e controlla la catena di [signer] alla data [at], usando
  /// anche i certificati [extra] contenuti nella firma.
  static ChainReport verify(Certificate signer, {List<Certificate> extra = const [], DateTime? at}) {
    final when = at ?? DateTime.now();
    final pool = [...intermediates, ...extra.where((c) => c != signer)];
    final path = <Certificate>[signer];
    var current = signer;
    for (var depth = 0; depth < 5; depth++) {
      for (final r in roots) {
        if (current.isIssuedBy(r)) {
          path.add(r);
          final valid = path.every((c) => c.isValidAt(when));
          return ChainReport(
            valid ? ChainStatus.cie : ChainStatus.cieExpired,
            path,
            signerAllowsSignature: signer.allowsDigitalSignature,
          );
        }
      }
      Certificate? next;
      for (final c in pool) {
        if (!path.contains(c) && c.isCa && current.isIssuedBy(c)) {
          next = c;
          break;
        }
      }
      if (next == null) break;
      path.add(next);
      current = next;
    }
    // Il nome dell'emittente è di una CA della CIE ma la firma non torna.
    final cieNames = [...roots, ...intermediates].map((c) => base64.encode(c.subjectDer)).toSet();
    final status = cieNames.contains(base64.encode(current.issuerDer)) ? ChainStatus.brokenChain : ChainStatus.unknownIssuer;
    return ChainReport(status, path, signerAllowsSignature: signer.allowsDigitalSignature);
  }
}
