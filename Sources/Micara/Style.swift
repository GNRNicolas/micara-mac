import AppKit

// MARK: - Style

/// Couleurs et géométrie. Rien ici n'est persisté ni exposé à l'utilisateur.
///
/// Repris d'Eyesaver, à une couleur près. Règle héritée et maintenue : ni blanc
/// pur ni noir pur nulle part où l'œil peut les voir — `ink` et `night` sont des
/// versions tièdes, tout le reste est un alpha de ces deux-là.
enum Style {
    /// Bleu d'accent, provisoire : Nicolas fournira le logo et sa palette.
    /// UNE seule constante, pour que le remplacement soit un `git grep accent`.
    /// Calibré plutôt que sRGB, comme l'orange d'Eyesaver : la valeur est
    /// choisie à l'œil sur fond sombre, pas convertie depuis un hex.
    ///
    /// Réservé au LISERÉ. La barre est en `ink`/`night` purs, exactement comme
    /// Eyesaver : c'est le liseré qui dit « réunion en cours », la barre n'a
    /// pas à le redire en couleur.
    static let accent = NSColor(calibratedRed: 0.24, green: 0.53, blue: 1.0, alpha: 1.0)

    /// Blanc cassé, #FBFBF2. Le blanc pur est dur sur le matériau sombre.
    static let ink = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF2 / 255, alpha: 1)
    /// Presque noir, #1E1E1C. Le pendant chaud de `ink`, utilisé pour le texte
    /// posé sur un aplat clair (bouton principal).
    static let night = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1C / 255, alpha: 1)

    // MARK: Liseré

    /// Moitié d'Eyesaver (12) : ici le liseré signale une réunion en cours, pas
    /// une alerte à ne pas rater. Il doit se remarquer sans mordre sur l'écran.
    static let borderWidth: CGFloat = 6
    /// Ne concerne que le bord INTÉRIEUR de l'anneau. Le bord extérieur épouse
    /// l'écran, dont les coins bas sont carrés.
    static let borderInnerRadius: CGFloat = 18
    /// Opacité fixe : pas de pulsation, contrairement à Eyesaver. Une réunion
    /// dure une heure, un clignotement d'une heure est insupportable.
    static let borderOpacity: Float = 0.9
    static let borderFade: TimeInterval = 0.22

    // MARK: Pill

    static let pillRadius: CGFloat = 16
    static let pillHeight: CGFloat = 60
    /// UNE seule marge, à gauche comme en bas (valeur d'Eyesaver). Le coin doit
    /// avoir l'air carré : deux constantes finissent toujours par diverger.
    ///
    /// Mesurée depuis le bord de l'ÉCRAN, pas depuis `visibleFrame`, pour
    /// l'axe vertical : un Dock en bas ferait remonter la barre de sa hauteur
    /// et le coin ne serait plus carré — et la barre bougerait selon que le
    /// Dock est masqué ou non. Horizontalement en revanche on part du bord
    /// utile, parce qu'un Dock latéral occupe vraiment la place où la barre
    /// irait (voir `Bar.targetFrame`).
    static let barMargin: CGFloat = 15
    /// Marges internes du contenu, gauche et droite.
    static let pillLeftInset: CGFloat = 16
    static let pillRightInset: CGFloat = 14

    // MARK: Vu-mètre

    static let meterWidth: CGFloat = 56
    /// Taille commune aux icônes du pill (micro, QR).
    static let iconBox: CGFloat = 22
    static let meterHeight: CGFloat = 8

    // MARK: Points téléphones

    static let dotSize: CGFloat = 8
    static let dotSpacing: CGFloat = 6
    /// Places réservées en dur, même quand la réunion est vide : c'est la
    /// limite du serveur (`MICARA_MAX_PHONES`, défaut 8). Réserver la zone est
    /// ce qui garantit que le pill ne bouge jamais d'un point de large.
    static let maxPhones = 8
    /// Les deux seules couleurs du pill : elles portent un SENS (ça marche /
    /// ça rame), pas une identité. Couleurs système, pour rester lisibles quel
    /// que soit le réglage de contraste de la machine.
    static let dotConnected = NSColor.systemGreen
    static let dotReconnecting = NSColor.systemOrange

    // MARK: Panneau QR

    /// Côté visé du QR. La taille réelle est arrondie à un multiple entier du
    /// module, pour que la matrice tombe pile sur la grille de points.
    static let qrTargetSide: CGFloat = 180
    static let qrPadding: CGFloat = 16
    /// Écart entre le haut du pill et le bas du panneau QR.
    static let qrGap: CGFloat = 10

    // MARK: Animations

    /// Durées et courbe communes à toutes les transitions, reprises d'Eyesaver :
    /// une apparition un peu plus lente que la disparition.
    static let appearDuration: TimeInterval = 0.22
    static let disappearDuration: TimeInterval = 0.16
    /// Délai anti-clignotement avant de replier le QR quand la souris sort.
    static let hoverGrace: TimeInterval = 0.15
}
