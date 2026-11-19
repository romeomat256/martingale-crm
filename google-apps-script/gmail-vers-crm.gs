/**
 * Martingale CRM : Gmail vers fiches clients
 * ------------------------------------------
 * Ce script lit ta boîte Gmail et envoie au CRM les mails échangés avec les contacts
 * qui ont une fiche (même adresse e-mail). Rien d'autre ne sort de Gmail :
 * fournisseurs, banque, newsletters et mails personnels sont ignorés à la source.
 * Le script ne fait que lire. Il n'envoie, ne modifie et ne supprime aucun mail.
 *
 * INSTALLATION (une seule fois)
 * 1. Ouvre script.google.com avec le compte Google de ta boîte Martingale, puis « Nouveau projet ».
 * 2. Supprime le contenu affiché et colle tout ce fichier. Enregistre.
 * 3. Roue crantée (Paramètres du projet) > Propriétés du script > Ajouter une propriété :
 *      nom    : CRM_SECRET
 *      valeur : la même clé que celle saisie dans Supabase (secret MESSAGES_INGEST_SECRET)
 * 4. Dans la liste des fonctions en haut, choisis « installer » puis clique sur Exécuter.
 *    Google demande l'autorisation d'accéder à Gmail : accepte
 *    (écran « application non validée » : Paramètres avancés > Accéder au projet).
 * 5. Pour reprendre les six derniers mois, exécute ensuite « reprendreHistorique ».
 *
 * ENSUITE, TOUT EST AUTOMATIQUE
 * - toutes les 10 minutes : les mails des 2 derniers jours
 * - chaque nuit : les 30 derniers jours (rattrape les fiches créées entre-temps)
 * Pour tout arrêter : exécute « desinstaller ».
 */

const CRM_URL = 'https://hduxtygzhesmclxanocj.supabase.co/functions/v1/messages-ingest';
const ADRESSES_PAR_RECHERCHE = 12;   // contacts regroupés dans une même recherche Gmail
const MESSAGES_PAR_ENVOI = 40;       // messages envoyés au CRM par appel
const TAILLE_MAX_TEXTE = 20000;      // caractères conservés par mail
const DUREE_MAX_MS = 5 * 60 * 1000;  // Google coupe un script à 6 minutes

/** À exécuter une fois : vérifie la connexion, pose les déclencheurs, fait un premier passage. */
function installer() {
  const contacts = appelCrm_('get', null);
  desinstaller();
  ScriptApp.newTrigger('synchroniser').timeBased().everyMinutes(10).create();
  ScriptApp.newTrigger('rattrapageNuit').timeBased().everyDays(1).atHour(3).create();
  Logger.log('Connexion au CRM : OK. ' + (contacts.emails || []).length + ' contacts avec e-mail.');
  const bilan = envoyerPeriode_(2);
  Logger.log('Installation terminée. Premier passage : ' + JSON.stringify(bilan));
}

/** Supprime les déclencheurs de ce script. */
function desinstaller() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (['synchroniser', 'rattrapageNuit'].indexOf(t.getHandlerFunction()) !== -1) ScriptApp.deleteTrigger(t);
  });
}

/** Toutes les 10 minutes. */
function synchroniser() { Logger.log(JSON.stringify(envoyerPeriode_(2))); }

/** Chaque nuit. */
function rattrapageNuit() { Logger.log(JSON.stringify(envoyerPeriode_(30))); }

/** À la main : reprend les 180 derniers jours. Si le bilan indique « interrompu », relance la fonction. */
function reprendreHistorique() { Logger.log(JSON.stringify(envoyerPeriode_(180))); }

// ─────────────────────────────────────────────────────────────

function envoyerPeriode_(jours) {
  const verrou = LockService.getScriptLock();
  if (!verrou.tryLock(1000)) return { ignore: 'un passage est déjà en cours' };
  try {
    const debut = Date.now();
    const moi = mesAdresses_();
    const contacts = appelCrm_('get', null);
    const emails = (contacts.emails || []).filter(function (e) { return moi.indexOf(e) === -1; });
    const bilan = { jours: jours, contacts: emails.length, lus: 0, envoyes: 0, enregistres: 0, interrompu: false };
    if (!emails.length) return bilan;

    const connus = {};
    emails.forEach(function (e) { connus[e] = true; });
    const cache = CacheService.getScriptCache();
    const vus = {};
    let lot = [];

    const vider = function () {
      if (!lot.length) return;
      const res = appelCrm_('post', { canal: 'gmail', self: moi, messages: lot });
      bilan.envoyes += lot.length;
      bilan.enregistres += res.stored || 0;
      const marques = {};
      lot.forEach(function (m) { marques['m_' + m.external_id] = '1'; });
      cache.putAll(marques, 21600); // 6 h : évite de renvoyer les mêmes mails à chaque passage
      lot = [];
    };

    for (let i = 0; i < emails.length && !bilan.interrompu; i += ADRESSES_PAR_RECHERCHE) {
      const groupe = emails.slice(i, i + ADRESSES_PAR_RECHERCHE);
      const requete = '{' + groupe.map(function (e) { return 'from:' + e + ' to:' + e + ' cc:' + e; }).join(' ') + '}'
        + ' newer_than:' + jours + 'd -in:spam -in:trash -in:chats';
      let depart = 0;
      while (true) {
        const fils = GmailApp.search(requete, depart, 50);
        if (!fils.length) break;
        fils.forEach(function (fil) {
          fil.getMessages().forEach(function (msg) {
            const id = msg.getId();
            if (vus[id]) return;
            vus[id] = true;
            if (msg.isDraft() || cache.get('m_' + id)) return;
            const de = msg.getFrom() || '';
            const a = [msg.getTo(), msg.getCc()].filter(function (v) { return v; }).join(', ');
            if (!adresses_(de + ', ' + a).some(function (x) { return connus[x]; })) return;
            bilan.lus++;
            const envoyeParMoi = adresses_(de).some(function (x) { return moi.indexOf(x) !== -1; });
            lot.push({
              external_id: id,
              thread_id: fil.getId(),
              direction: envoyeParMoi ? 'out' : 'in',
              from: de,
              to: a,
              subject: msg.getSubject() || '',
              content: (msg.getPlainBody() || '').slice(0, TAILLE_MAX_TEXTE),
              sent_at: msg.getDate().toISOString(),
              attachments: piecesJointes_(msg)
            });
            if (lot.length >= MESSAGES_PAR_ENVOI) vider();
          });
        });
        depart += fils.length;
        if (Date.now() - debut > DUREE_MAX_MS) { bilan.interrompu = true; break; }
        if (fils.length < 50) break;
      }
    }
    vider();
    return bilan;
  } finally {
    verrou.releaseLock();
  }
}

/** Noms et tailles des pièces jointes. Le contenu des fichiers n'est pas envoyé. */
function piecesJointes_(msg) {
  try {
    return msg.getAttachments({ includeInlineImages: false, includeAttachments: true }).map(function (p) {
      return { name: p.getName(), size: p.getSize(), type: p.getContentType() };
    });
  } catch (e) {
    return [];
  }
}

/** "Prénom Nom <a@b.fr>, c@d.fr" -> ["a@b.fr", "c@d.fr"] */
function adresses_(texte) {
  return String(texte || '').toLowerCase().match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/g) || [];
}

/** Ton adresse et tes alias d'envoi : servent à distinguer « envoyé » de « reçu ». */
function mesAdresses_() {
  const liste = [Session.getEffectiveUser().getEmail()].concat(GmailApp.getAliases());
  return liste.filter(function (v) { return v; }).map(function (v) { return v.toLowerCase(); });
}

function appelCrm_(methode, donnees) {
  const cle = PropertiesService.getScriptProperties().getProperty('CRM_SECRET');
  if (!cle) throw new Error('Propriété CRM_SECRET manquante : Paramètres du projet > Propriétés du script.');
  const options = { method: methode, headers: { 'x-crm-secret': cle }, muteHttpExceptions: true };
  if (donnees) {
    options.contentType = 'application/json';
    options.payload = JSON.stringify(donnees);
  }
  const reponse = UrlFetchApp.fetch(CRM_URL, options);
  const code = reponse.getResponseCode();
  if (code === 401) throw new Error('Clé refusée par le CRM : CRM_SECRET ne correspond pas au secret saisi dans Supabase.');
  if (code === 503) throw new Error('Le secret MESSAGES_INGEST_SECRET n\'est pas encore enregistré dans Supabase.');
  if (code !== 200) throw new Error('Le CRM a répondu ' + code + ' : ' + reponse.getContentText().slice(0, 200));
  return JSON.parse(reponse.getContentText());
}
