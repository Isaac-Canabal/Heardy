import type { Metadata } from "next";
import Link from "next/link";

import { LegalNote, LegalPage, LegalSection } from "@/components/legal-page";
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
          El operador no controla, revisa ni aprueba los enlaces que el usuario introduce, no conserva
          el audio extraído y no adquiere ningún derecho sobre él. El operador se reserva el derecho a
          limitar, suspender o retirar esta función en cualquier momento, incluida la posibilidad de
          bloquear enlaces o cuentas ante indicios de uso indebido.
        </p>
        <LegalNote>
          conviene que un abogado confirme el encaje de esta función con la excepción de copia privada
          y con las obligaciones de intermediarios en Colombia y en los países de destino previstos.
        </LegalNote>
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
          Para usar Heardy debes tener al menos 14 años. Si la legislación de tu país exige una edad
          superior para aceptar condiciones de uso o para el tratamiento de datos personales sin
          autorización de los padres o tutores, se aplica esa edad. Los menores de edad que usen la
          cuenta opcional deben hacerlo con el conocimiento y la autorización de sus padres o tutores.
        </p>
        <LegalNote>
          la edad de 14 años sigue el criterio general del ordenamiento colombiano para el
          consentimiento de adolescentes; revisar si conviene exigir directamente la mayoría de edad
          para la cuenta opcional.
        </LegalNote>
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

      <LegalSection id="derechos-autor" title="8. Reclamaciones de derechos de autor y retirada de contenido">
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
          El operador analizará la notificación en un plazo razonable, podrá retirar o desactivar el
          acceso al dato señalado y podrá informar al usuario afectado, quien tendrá la posibilidad de
          presentar una respuesta. Las notificaciones abusivas o de mala fe podrán ser desestimadas.
        </p>
        <LegalNote>
          este procedimiento es una versión simplificada; un abogado debería adaptarlo al régimen de
          responsabilidad de intermediarios que resulte aplicable.
        </LegalNote>
      </LegalSection>

      <LegalSection id="terminacion" title="9. Suspensión y terminación">
        <p>
          El usuario puede dejar de usar Heardy en cualquier momento desinstalando la aplicación y, si
          tiene cuenta, borrando sus datos desde Ajustes. El operador puede suspender o cancelar el
          acceso a los servicios opcionales de un usuario que incumpla estos términos, o descontinuar
          dichos servicios en su conjunto con un preaviso razonable cuando sea posible. La aplicación
          seguirá funcionando en modo local aunque los servicios opcionales dejen de prestarse.
        </p>
      </LegalSection>

      <LegalSection id="ley" title="10. Ley aplicable y jurisdicción">
        <p>
          Estos términos se rigen por las leyes de la República de Colombia. Cualquier controversia se
          someterá a los jueces competentes de Colombia, sin perjuicio de las normas imperativas de
          protección al consumidor que puedan resultar aplicables en el país de residencia del usuario.
        </p>
      </LegalSection>

      <LegalSection id="cambios" title="11. Cambios en los términos">
        <p>
          Podemos modificar estos términos para reflejar cambios en la aplicación, en los servicios o
          en la legislación. La versión vigente estará siempre publicada en esta página con su fecha de
          actualización. Si el cambio es sustancial, lo indicaremos de forma visible en el sitio web o
          en la aplicación. El uso continuado de Heardy tras la publicación de los cambios implica su
          aceptación.
        </p>
      </LegalSection>

      <LegalSection id="contacto" title="12. Contacto">
        <p>
          Consultas generales: <a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a>.
          Reclamaciones de derechos de autor:{" "}
          <a href={`mailto:${site.legalEmail}`}>{site.legalEmail}</a>. Privacidad y datos personales:{" "}
          <a href={`mailto:${site.privacyEmail}`}>{site.privacyEmail}</a>.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
