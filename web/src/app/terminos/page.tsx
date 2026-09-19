import type { Metadata } from "next";
import Link from "next/link";

import { LegalPage, LegalSection } from "@/components/legal-page";
import { site } from "@/content/site";

export const metadata: Metadata = {
  title: "Términos de uso",
  description: "Condiciones de uso de Heardy, el reproductor de música local para Android y Windows.",
};

export default function TermsPage() {
  return (
    <LegalPage
      title="Términos de uso"
      intro="Estas condiciones regulan la descarga y el uso de la aplicación Heardy y de los servicios opcionales asociados a ella. Al instalar o usar Heardy aceptas estos términos."
    >
      <LegalSection id="servicio" title="1. Qué es Heardy">
        <p>
          Heardy es una aplicación gratuita y de código abierto para Android y Windows que reproduce
          archivos de audio almacenados en el dispositivo del usuario. Permite organizar esos archivos
          en playlists, mostrar letras sincronizadas y su traducción, consultar estadísticas de
          escucha y, de forma opcional, mantener una cuenta para sincronizar un índice de la biblioteca
          entre los dispositivos del propio usuario y compartir ciertos datos con otros usuarios que el
          usuario haya aceptado como amigos.
        </p>
        <p>
          El operador de Heardy es {site.operatorName}, con domicilio en {site.operatorLocation} (en
          adelante, «el operador» o «nosotros»).
        </p>
      </LegalSection>

      <LegalSection id="reproductor-local" title="2. Heardy es un reproductor local">
        <p>
          Heardy no es un servicio de música por suscripción ni un catálogo de contenidos. La
          aplicación reproduce únicamente archivos que ya se encuentran en el almacenamiento del
          dispositivo, en la carpeta que el usuario elige. El operador no aloja, almacena, transmite,
          distribuye ni pone a disposición de terceros ningún archivo de audio: el audio nunca sale del
          dispositivo del usuario, ni siquiera cuando se utiliza la cuenta opcional (véase la sección 5).
        </p>
      </LegalSection>

      <LegalSection id="contenido-terceros" title="3. Importación desde enlaces y contenido de terceros">
        <p>
          De forma secundaria y opcional, Heardy permite importar audio a la biblioteca local a partir
          de un enlace a plataformas de terceros, mediante un servidor de extracción operado por el
          operador o por el propio usuario. El uso de esta función es exclusiva responsabilidad del
          usuario. Al utilizarla, el usuario declara y garantiza que:
        </p>
        <ul>
          <li>
            tiene derecho a obtener y conservar una copia del contenido en cuestión, por ejemplo porque
            lo ha adquirido, cuenta con una licencia que lo permite, es contenido de su propia autoría o
            se encuentra en el dominio público;
          </li>
          <li>
            respeta las condiciones de uso de la plataforma de origen y la legislación aplicable en
            materia de derechos de autor y derechos conexos, en particular la Ley 23 de 1982 y la Ley
            1915 de 2018 de Colombia y las normas equivalentes de su país de residencia;
          </li>
          <li>
            utiliza el contenido importado únicamente para uso personal y privado, sin fines
            comerciales y sin redistribuirlo ni comunicarlo públicamente.
          </li>
        </ul>
        <p>
          El servidor actúa como una herramienta técnica que ejecuta, a petición expresa del usuario y
          para él, la obtención de un archivo concreto; el operador no selecciona, controla, revisa ni
          aprueba los enlaces que el usuario introduce, no conserva el audio extraído más allá de una
          caché técnica temporal, no lo pone a disposición de otros usuarios y no adquiere ningún
          derecho sobre él. El operador se reserva el derecho a limitar, suspender o retirar esta
          función en cualquier momento, incluida la posibilidad de bloquear enlaces o cuentas ante
          indicios de uso indebido, y atenderá los requerimientos legítimos de autoridades y titulares
          de derechos conforme a la sección 9.
        </p>
      </LegalSection>

      <LegalSection id="uso-permitido" title="4. Uso permitido y prohibiciones">
        <p>Heardy se ofrece para uso personal y no comercial. Queda prohibido:</p>
        <ul>
          <li>usar Heardy o sus servicios asociados con fines comerciales o para redistribuir contenido;</li>
          <li>revender, alquilar o sublicenciar el acceso a los servicios asociados a la cuenta;</li>
          <li>
            intentar eludir límites técnicos, cuotas de uso o mecanismos de autenticación del servidor
            opcional, o sobrecargarlo de forma deliberada;
          </li>
          <li>
            usar la función de amigos o de nombre de usuario para acosar, suplantar o localizar a otras
            personas, o elegir nombres de usuario ofensivos o que induzcan a confusión;
          </li>
          <li>usar Heardy para infringir derechos de terceros o la ley aplicable.</li>
        </ul>
        <p>
          El código fuente de Heardy se publica bajo la licencia MIT (véase{" "}
          <Link href="/licencias">Licencias</Link>). Esa licencia regula el uso del código; estos
          términos regulan el uso de la aplicación compilada distribuida por el operador y de los
          servicios asociados.
        </p>
      </LegalSection>

      <LegalSection id="cuenta" title="5. Cuenta opcional">
        <p>
          Todas las funciones esenciales de Heardy (biblioteca, reproducción, playlists, letras,
          estadísticas) funcionan sin cuenta y sin conexión. Crear una cuenta es opcional y permite:
          sincronizar entre los dispositivos del usuario un índice de su biblioteca (títulos, artistas,
          duración, playlists y el enlace de origen de una canción cuando exista), su historial de
          reproducción y sus estadísticas; elegir un nombre de usuario; enviar y aceptar solicitudes de
          amistad; y, si se activa expresamente, compartir con los amigos la canción que se está
          escuchando en cada momento.
        </p>
        <p>
          La cuenta se gestiona a través de un proveedor de identidad externo; el operador nunca ve ni
          almacena la contraseña del usuario. Es necesario verificar el correo electrónico para usar
          los servicios que requieren cuenta. El usuario es responsable de mantener la confidencialidad
          de sus credenciales. El detalle de qué datos se tratan, con qué finalidad y durante cuánto
          tiempo está en la <Link href="/privacidad">Política de privacidad</Link>. El usuario puede
          borrar todos los datos asociados a su cuenta en cualquier momento desde Ajustes («Borrar mis
          datos de la nube»).
        </p>
      </LegalSection>

      <LegalSection id="edad" title="6. Edad mínima">
        <p>
          Para usar Heardy debes tener al menos 14 años. Para crear la cuenta opcional (que implica el
          tratamiento de datos personales) debes ser mayor de edad conforme a la ley de tu país; los
          mayores de 14 y menores de edad solo pueden crearla con la autorización de sus padres o
          tutores, quienes responden de ese uso. Si tu legislación exige una edad superior para
          aceptar condiciones de uso o para consentir el tratamiento de datos, se aplica esa edad.
        </p>
      </LegalSection>

      <LegalSection id="garantias" title="7. Sin garantías y limitación de responsabilidad">
        <p>
          Heardy se proporciona «tal cual» y «según disponibilidad», sin garantías de ningún tipo,
          expresas o implícitas, incluidas las de comerciabilidad, idoneidad para un fin determinado,
          disponibilidad continua o ausencia de errores. El operador no garantiza que la aplicación sea
          compatible con todos los dispositivos ni que los servicios opcionales estén disponibles de
          forma ininterrumpida; el servidor opcional puede tener cuotas de uso, interrupciones o dejar
          de prestarse.
        </p>
        <p>
          En la máxima medida permitida por la ley, el operador no será responsable de daños
          indirectos, incidentales, especiales o consecuentes, ni de pérdida de datos, archivos o
          beneficios derivados del uso o de la imposibilidad de uso de Heardy. Se recomienda al usuario
          mantener copias de seguridad de su música y de sus datos. Nada en estos términos limita los
          derechos que la legislación de protección al consumidor reconozca al usuario de forma
          irrenunciable.
        </p>
      </LegalSection>

      <LegalSection id="responsabilidad" title="8. Responsabilidad del usuario por el contenido e indemnidad">
        <p>
          Todo el contenido que reproduces, importas, almacenas o sincronizas con Heardy es tuyo o lo
          obtienes tú: el operador no lo elige, no lo revisa y no lo aloja. Por eso, <strong>eres el
          único responsable</strong> de que ese contenido y el uso que hagas de él respeten los
          derechos de terceros (en particular los derechos de autor y conexos), las condiciones de las
          plataformas de origen y la ley aplicable. Si importas o conservas contenido sin tener derecho
          a ello, la responsabilidad es exclusivamente tuya.
        </p>
        <p>
          Te comprometes a <strong>mantener indemne</strong> al operador, a sus colaboradores y
          proveedores frente a cualquier reclamación, sanción, daño o gasto (incluidos honorarios
          legales razonables) que se derive del contenido que hayas reproducido, importado, almacenado
          o compartido a través de Heardy, de tu incumplimiento de estos términos o de tu infracción de
          derechos de terceros o de la ley. El operador podrá cooperar con autoridades y titulares de
          derechos en la medida que la ley exija.
        </p>
      </LegalSection>

      <LegalSection id="derechos-autor" title="9. Reclamaciones de derechos de autor y retirada de contenido">
        <p>
          El operador respeta los derechos de propiedad intelectual y espera lo mismo de los usuarios.
          Dado que el operador no aloja audio, las reclamaciones sobre archivos concretos deben
          dirigirse a la plataforma o al dispositivo donde se encuentren. No obstante, si consideras que
          un enlace de origen almacenado en el índice de un usuario, un nombre de usuario u otro dato
          gestionado por el operador infringe tus derechos, puedes notificarlo a{" "}
          <a href={`mailto:${site.legalEmail}`}>{site.legalEmail}</a> indicando:
        </p>
        <ol>
          <li>tu identificación y datos de contacto, y en su caso la acreditación de que actúas en nombre del titular;</li>
          <li>la identificación de la obra u objeto protegido y del dato o enlace supuestamente infractor;</li>
          <li>una declaración de buena fe de que el uso no está autorizado por el titular, su representante o la ley;</li>
          <li>una declaración de que la información facilitada es exacta.</li>
        </ol>
        <p>
          El operador acusará recibo y analizará la notificación en un plazo máximo de quince días
          hábiles; si resulta fundada, retirará o desactivará el acceso al dato señalado e informará al
          usuario afectado, quien podrá presentar una respuesta con la misma información y bajo la misma
          declaración de buena fe. El dato se mantendrá retirado salvo que la respuesta acredite que el
          uso es lícito o que el reclamante desista. Las notificaciones incompletas, abusivas o de mala
          fe podrán ser desestimadas, y el operador podrá suspender las cuentas que reincidan en
          infracciones acreditadas.
        </p>
      </LegalSection>

      <LegalSection id="terminacion" title="10. Suspensión y terminación">
        <p>
          El usuario puede dejar de usar Heardy en cualquier momento desinstalando la aplicación y, si
          tiene cuenta, borrando sus datos desde Ajustes. El operador puede suspender o cancelar el
          acceso a los servicios opcionales de un usuario que incumpla estos términos, o descontinuar
          dichos servicios en su conjunto con un preaviso razonable cuando sea posible. La aplicación
          seguirá funcionando en modo local aunque los servicios opcionales dejen de prestarse.
        </p>
      </LegalSection>

      <LegalSection id="ley" title="11. Ley aplicable y resolución de controversias">
        <p>
          Estos términos se rigen por las leyes de la República de Colombia. Antes de iniciar cualquier
          acción, las partes intentarán resolver la controversia de forma directa: la parte afectada
          la notificará por escrito a la otra (el usuario, a {site.contactEmail}; el operador, al correo
          de la cuenta) y ambas dispondrán de treinta (30) días para llegar a un acuerdo.
        </p>
        <p>
          Si no hay acuerdo, toda controversia derivada de estos términos o del uso de Heardy se
          resolverá mediante <strong>arbitraje en derecho</strong> conforme a la Ley 1563 de 2012, ante
          el Centro de Arbitraje y Conciliación de la Cámara de Comercio de Bogotá, por un árbitro único
          designado según su reglamento, con sede en Bogotá y en idioma español. El laudo será
          definitivo y vinculante. Cada parte asumirá sus propios costos, salvo que el laudo disponga
          otra cosa.
        </p>
        <p>
          Cuando actúes como consumidor y la legislación que te proteja te reconozca el derecho a
          acudir a la jurisdicción ordinaria o a la autoridad de protección al consumidor (en Colombia,
          la Superintendencia de Industria y Comercio), este arbitraje es <strong>opcional para ti</strong>{" "}
          y no limita ese derecho. En la medida permitida por la ley, las controversias se resolverán de
          forma individual, no mediante acciones colectivas o de grupo.
        </p>
      </LegalSection>

      <LegalSection id="cambios" title="12. Cambios en los términos">
        <p>
          Podemos modificar estos términos para reflejar cambios en la aplicación, en los servicios o
          en la legislación. La versión vigente estará siempre publicada en esta página con su fecha de
          actualización. Si el cambio es sustancial, lo indicaremos de forma visible en el sitio web o
          en la aplicación. El uso continuado de Heardy tras la publicación de los cambios implica su
          aceptación.
        </p>
      </LegalSection>

      <LegalSection id="aceptacion" title="13. Aceptación">
        <p>
          Aceptas estos términos al marcar la casilla correspondiente antes de descargar la aplicación
          desde este sitio y, de nuevo, al aceptarlos dentro de la aplicación la primera vez que la
          abres; en ambos casos se registra la versión aceptada y la fecha. Si no estás de acuerdo con
          ellos, no instales ni uses Heardy.
        </p>
      </LegalSection>

      <LegalSection id="ia" title="14. Uso de inteligencia artificial en el desarrollo">
        <p>
          Heardy se desarrolla con asistencia de herramientas de inteligencia artificial para escribir
          y revisar código, textos y documentación, siempre bajo supervisión humana. Ningún dato
          personal de los usuarios ni el contenido de sus bibliotecas se utiliza para entrenar modelos
          ni se comparte con proveedores de inteligencia artificial.
        </p>
      </LegalSection>

      <LegalSection id="contacto" title="15. Contacto">
        <p>
          Consultas, reclamaciones de derechos de autor y asuntos de privacidad:{" "}
          <a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a>.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
