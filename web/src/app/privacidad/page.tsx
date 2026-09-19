import type { Metadata } from "next";
import Link from "next/link";

import { LegalPage, LegalSection } from "@/components/legal-page";
import { site } from "@/content/site";

export const metadata: Metadata = {
  title: "Política de privacidad",
  description: "Qué datos trata Heardy, cuáles no, dónde se procesan y qué derechos tienes sobre ellos.",
};

const providers = [
  {
    name: "Google (Firebase Authentication)",
    role: "Identidad de la cuenta: correo electrónico, verificación y sesión.",
    policy: "https://firebase.google.com/support/privacy",
  },
  {
    name: "Render",
    role: "Alojamiento del servidor opcional (sincronización, amigos, extracción desde enlaces).",
    policy: "https://render.com/privacy",
  },
  {
    name: "Neon",
    role: "Base de datos donde se guarda el índice de biblioteca, historial, nombre de usuario y amistades.",
    policy: "https://neon.tech/privacy-policy",
  },
];

export default function PrivacyPage() {
  return (
    <LegalPage
      title="Política de privacidad"
      intro="Heardy está diseñado para que la mayor parte de tus datos no salga nunca de tu dispositivo. Esta política explica qué información se trata cuando decides usar las funciones opcionales que sí requieren un servidor, y qué derechos tienes sobre ella."
      draft={false}
    >
      <LegalSection id="responsable" title="1. Responsable del tratamiento">
        <p>
          {site.operatorName}, {site.operatorLocation}. Contacto para asuntos de privacidad:{" "}
          <a href={`mailto:${site.privacyEmail}`}>{site.privacyEmail}</a>.
        </p>
      </LegalSection>

      <LegalSection id="sin-cuenta" title="2. Uso sin cuenta: nada sale de tu dispositivo">
        <p>
          Si usas Heardy sin crear una cuenta, toda la información (tu biblioteca, playlists,
          historial de reproducción, estadísticas, ajustes) se guarda únicamente en tu dispositivo y
          el operador no recibe ningún dato. Las únicas conexiones a internet que puede hacer la
          aplicación en este modo son las necesarias para obtener letras y traducciones de las
          canciones que reproduces, que se solicitan a servicios de terceros enviando el título, el
          artista y la duración de la canción, sin ningún identificador tuyo.
        </p>
      </LegalSection>

      <LegalSection id="datos" title="3. Qué datos tratamos si creas una cuenta">
        <ul>
          <li>
            <strong>Correo electrónico y estado de verificación</strong>, gestionados por el proveedor
            de identidad. El operador nunca ve ni almacena tu contraseña.
          </li>
          <li>
            <strong>Índice de tu biblioteca</strong>: títulos, artistas, álbum, duración, una huella
            del contenido de audio (un valor derivado del archivo que no permite reconstruirlo),
            playlists y su composición, y el enlace de origen de una canción cuando fue importada
            desde un enlace. Nunca se envían rutas de archivos ni el audio.
          </li>
          <li>
            <strong>Historial de reproducción</strong>: qué canción escuchaste, cuándo y durante
            cuánto tiempo (este último valor se acota en el servidor y no se toma como dato fiable).
          </li>
          <li>
            <strong>Nombre de usuario</strong>, si eliges uno, y las <strong>relaciones de amistad</strong>{" "}
            (solicitudes enviadas, aceptadas y rechazadas).
          </li>
          <li>
            <strong>«Escuchando ahora»</strong>, solo si activas expresamente esta opción: la canción
            que reproduces en cada momento, visible solo para tus amigos y que caduca automáticamente
            al terminar la canción. Está desactivada por defecto.
          </li>
          <li>
            <strong>Datos técnicos mínimos</strong> necesarios para operar el servicio: contadores de
            uso por cuenta (para aplicar cuotas), marcas de tiempo de sincronización y registros del
            servidor. Los registros no combinan nunca tu identidad con el contenido de tus datos.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="no-recogemos" title="4. Qué no recogemos">
        <ul>
          <li>Tus archivos de audio: el audio nunca sale de tu dispositivo.</li>
          <li>Rutas de archivos, nombres de carpetas ni la estructura de tu almacenamiento.</li>
          <li>Datos de analítica, seguimiento de uso o publicidad: Heardy no incorpora ningún SDK de analítica ni de anuncios.</li>
          <li>Contactos, ubicación, micrófono ni ningún otro permiso ajeno a leer tu carpeta de música.</li>
          <li>Datos de pago: Heardy es gratuito.</li>
        </ul>
      </LegalSection>

      <LegalSection id="finalidades" title="5. Finalidades y base legal">
        <p>
          Los datos de la cuenta se tratan exclusivamente para prestar las funciones que tú activas:
          sincronizar tu índice e historial entre tus dispositivos, restaurarlos tras una
          reinstalación, gestionar tu nombre de usuario y tus amistades, y mostrar a tus amigos lo
          que escuchas si así lo decides. También los usamos, de forma agregada y sin identificarte,
          para mantener la seguridad y aplicar límites de uso al servicio.
        </p>
        <p>
          La base legal es tu <strong>autorización previa, expresa e informada</strong> (artículo 9 de
          la Ley 1581 de 2012 de Colombia), que otorgas al crear la cuenta y vincularla, momento en el
          que la aplicación te informa de que el índice y el historial viajarán al servidor. Para los
          usuarios de la Unión Europea, la base legal equivalente es el consentimiento y la ejecución
          del servicio solicitado (artículo 6.1.a y 6.1.b del RGPD). Puedes retirar la autorización en
          cualquier momento borrando tus datos (sección 9).
        </p>
      </LegalSection>

      <LegalSection id="donde" title="6. Dónde se procesan los datos y encargados">
        <p>
          El servidor opcional y la base de datos se ejecutan en infraestructura de proveedores
          externos que actúan como encargados del tratamiento y que alojan los datos en los Estados
          Unidos. Esto supone una transferencia internacional de datos, que se ampara en tu
          autorización previa, expresa e informada (artículo 26 de la Ley 1581 de 2012 y Circular
          Externa 005 de 2017 de la Superintendencia de Industria y Comercio) y en los acuerdos de
          tratamiento de datos de dichos proveedores, que incluyen las cláusulas contractuales tipo
          aprobadas por la Comisión Europea para los usuarios de la Unión Europea.
        </p>
        <ul>
          {providers.map((p) => (
            <li key={p.name}>
              <strong>{p.name}</strong> — {p.role}{" "}
              <a href={p.policy} target="_blank" rel="noopener noreferrer">
                Política de privacidad
              </a>
              .
            </li>
          ))}
        </ul>
        <p>
          Para las letras y traducciones, la aplicación consulta servicios de terceros enviando solo
          los metadatos de la canción (véase <Link href="/licencias">Licencias y créditos</Link>).
          No cedemos tus datos a ningún otro tercero ni los vendemos.
        </p>
      </LegalSection>

      <LegalSection id="compartir" title="7. Qué ven otros usuarios">
        <p>
          Un usuario que no sea tu amigo solo puede comprobar si un nombre de usuario exacto existe, y
          nunca ve tu correo, el tamaño de tu biblioteca ni tus estadísticas. Tus amigos pueden ver tu
          nombre de usuario, tus estadísticas de escucha (canciones y artistas más escuchados, totales)
          y, únicamente si lo has activado, la canción que estás escuchando. Puedes retirar una amistad
          en cualquier momento.
        </p>
      </LegalSection>

      <LegalSection id="retencion" title="8. Conservación">
        <p>
          Los datos de tu cuenta se conservan mientras la cuenta exista. La información de «escuchando
          ahora» caduca automáticamente al terminar cada canción y no se almacena de forma permanente.
          Los registros técnicos del servidor se conservan como máximo 30 días. Al borrar tus datos
          (sección 9) se eliminan de la base de datos de forma inmediata; las copias de seguridad
          automáticas del proveedor de base de datos se purgan en un plazo máximo de 30 días
          adicionales. Si el servicio opcional dejara de prestarse, los datos de todas las cuentas se
          eliminarían en ese mismo plazo.
        </p>
      </LegalSection>

      <LegalSection id="derechos" title="9. Tus derechos y cómo borrar tus datos">
        <p>
          Conforme a la Ley 1581 de 2012 y al Decreto 1377 de 2013 de Colombia (habeas data) tienes
          derecho a <strong>conocer, actualizar y rectificar</strong> tus datos, a{" "}
          <strong>solicitar prueba de la autorización</strong>, a ser informado del uso que se les ha
          dado, a <strong>revocar la autorización y solicitar la supresión</strong> de los datos y a
          presentar quejas ante la Superintendencia de Industria y Comercio. Los usuarios de la Unión
          Europea tienen además los derechos de acceso, rectificación, supresión, limitación,
          portabilidad y oposición previstos en el RGPD, y pueden reclamar ante su autoridad de control.
        </p>
        <p>
          La forma más rápida de ejercer la supresión es desde la propia aplicación:{" "}
          <strong>Ajustes → Cuenta → «Borrar mis datos de la nube»</strong>. Esta acción elimina del
          servidor tu índice, historial, nombre de usuario y amistades. Tus datos locales permanecen en
          tu dispositivo y siguen siendo tuyos. Para cualquier otra solicitud, escríbenos a{" "}
          <a href={`mailto:${site.privacyEmail}`}>{site.privacyEmail}</a> desde el correo asociado a tu
          cuenta; responderemos en los plazos que marca la ley (diez días hábiles para consultas y
          quince para reclamos, prorrogables según la norma colombiana; un mes según el RGPD).
        </p>
      </LegalSection>

      <LegalSection id="seguridad" title="10. Seguridad">
        <p>
          La comunicación entre la aplicación y el servidor se cifra en tránsito. El acceso al
          servidor exige un token de sesión emitido por el proveedor de identidad, que caduca de forma
          periódica. El servidor no almacena contraseñas ni audio, aplica cuotas por cuenta y no
          registra tu identidad junto con el contenido de tus datos. Ningún sistema es infalible; si
          detectamos un incidente que afecte a tus datos, te lo notificaremos conforme a la ley.
        </p>
      </LegalSection>

      <LegalSection id="menores" title="11. Menores de edad">
        <p>
          Heardy no está dirigido a menores de 14 años y no crea cuentas a sabiendas para ellos. La
          cuenta opcional está pensada para mayores de edad; un mayor de 14 años y menor de edad solo
          puede crearla con la autorización de sus padres o tutores, en los términos del artículo 7 de
          la Ley 1581 de 2012 y del artículo 12 del Decreto 1377 de 2013. Si crees que un menor ha
          facilitado datos sin esa autorización, escríbenos y los eliminaremos.
        </p>
      </LegalSection>

      <LegalSection id="cambios" title="12. Cambios en esta política">
        <p>
          Publicaremos cualquier cambio en esta página con su fecha de actualización y, si el cambio
          afecta de forma sustancial al tratamiento de tus datos, te lo indicaremos en la aplicación
          antes de que surta efecto.
        </p>
      </LegalSection>

      <LegalSection id="contacto" title="13. Contacto">
        <p>
          <a href={`mailto:${site.privacyEmail}`}>{site.privacyEmail}</a> · {site.operatorName},{" "}
          {site.operatorLocation}. Términos de uso: <Link href="/terminos">/terminos</Link>.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
