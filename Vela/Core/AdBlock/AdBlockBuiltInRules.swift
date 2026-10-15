//
//  AdBlockBuiltInRules.swift
//  Vela
//
//  The rule list that ships inside the app.
//
//  Three source identities ship enabled, each with a small curated rule body
//  behind it. The body is short on purpose: WebKit caps a content-rule list at
//  150,000 rules, and a shipped list has to leave room for whatever the user
//  subscribes to on top of it. The intent is to cover the common case out of the
//  box and let subscriptions supply the depth.
//

import Foundation

public enum AdBlockBuiltInRules {
    public static let builtInSourceId = "system-built-in-adblock-rules"

    public static let smoothModeSourceId = "system-smooth-mode-adblock-rules"

    public static let appPromotionBannerSourceId = "system-app-promotion-banner-rules"

    /// The shipped sources, in the order they are listed in settings.
    public static var sources: [AdBlockCustomRuleSource] {
        [
            AdBlockCustomRuleSource(
                id: builtInSourceId,
                name: "内置基础规则",
                sourceType: .system,
                enabled: true
            ),
            AdBlockCustomRuleSource(
                id: smoothModeSourceId,
                name: "内置流畅模式规则",
                sourceType: .system,
                enabled: true
            ),
            AdBlockCustomRuleSource(
                id: appPromotionBannerSourceId,
                name: "内置应用推广横幅规则",
                sourceType: .system,
                enabled: true
            )
        ]
    }

    /// Rule text keyed by source id.
    public static var filterLists: [String: String] {
        [
            builtInSourceId: baseRules,
            smoothModeSourceId: smoothModeRules,
            appPromotionBannerSourceId: appPromotionBannerRules
        ]
    }

    /// Common ad and tracker hosts, plus the cosmetic selectors that catch the
    /// in-page slots those hosts fill.
    private static let baseRules = """
    ! Vela built-in base rules
    ! Network rules
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^
    ||google-analytics.com^
    ||googletagmanager.com^
    ||googletagservices.com^
    ||adservice.google.com^
    ||pagead2.googlesyndication.com^
    ||amazon-adsystem.com^
    ||adsrvr.org^
    ||adnxs.com^
    ||criteo.com^
    ||criteo.net^
    ||outbrain.com^
    ||taboola.com^
    ||scorecardresearch.com^
    ||quantserve.com^
    ||moatads.com^
    ||advertising.com^
    ||pubmatic.com^
    ||rubiconproject.com^
    ||smartadserver.com^
    ||casalemedia.com^
    ||sharethrough.com^
    ||teads.tv^
    ||zedo.com^
    ||media.net^
    ||yieldmo.com^
    ||smaato.net^
    ||mopub.com^
    ||umeng.com^
    ||cnzz.com^
    ||hm.baidu.com^
    ||pos.baidu.com^
    ||cpro.baidu.com^
    ||dup.baidustatic.com^
    ||union.baidu.com^
    ||tanx.com^
    ||alimama.com^
    ||mmstat.com^
    ||admaster.com.cn^
    ||miaozhen.com^
    ||ipinyou.com^
    ||channel-tools.com^
    ||gdt.qq.com^
    ||e.qq.com^
    ||pingjs.qq.com^
    ||bugly.qq.com^
    ||sensorsdata.cn^
    ||growingio.com^
    ||talkingdata.com^
    ||umtrack.com^
    ||adview.cn^
    ||domob.cn^
    ||casstime.com^
    ||mobads.baidu.com^
    ||ad.duapps.com^
    ||adservice.google.cn^
    ||ads.youtube.com^
    ! Cosmetic rules
    ##.ad-banner
    ##.ad-container
    ##.ad-wrapper
    ##.advertisement
    ##.adsbygoogle
    ##.ad-slot
    ##.ad-placeholder
    ##.banner-ad
    ##.sponsored-content
    ##.promoted-content
    ##[id^="div-gpt-ad"]
    ##[id^="google_ads_"]
    ##[class^="adsbygoogle"]
    ##iframe[src*="doubleclick.net"]
    ##iframe[src*="googlesyndication.com"]
    ##iframe[src*="tanx.com"]
    ##div[data-ad-slot]
    ##div[data-ad-client]
    """

    /// Cosmetic rules that catch the self-promotion blocks a lot of sites open
    /// with, without touching anything that carries content.
    private static let smoothModeRules = """
    ! Vela built-in smooth-mode rules
    ! Site-published app promotion banners and interstitials.
    ##.open-in-app
    ##.openapp-banner
    ##.app-download-banner
    ##.app-download-bar
    ##.app-download-guide
    ##.download-app-guide
    ##.app-promotion
    ##.smart-banner
    ##.app-open-banner
    ##.open-in-client
    ##[id^="openInApp"]
    ##[class^="openInApp"]
    ##[id^="app-download"]
    ##[class^="appDownload"]
    ! Anti-adblock overlays: the notice a site shows when it detects blocking.
    ##.adblock-detected
    ##.adblock-notice
    ##.adblock-warning
    ##.ad-block-notice
    ##[class^="adblock-message"]
    ! Reading-progress promotion strips.
    ##.login-guide-banner
    ##.login-prompt-bar
    """

    /// The floating app-promotion banner rule set, kept as its own source so it
    /// can be switched off on its own.
    private static let appPromotionBannerRules = """
    ! Vela built-in app promotion banner rules
    ##.float-app-banner
    ##.fixed-download-bar
    ##.bottom-download-bar
    ##.bottom-app-bar
    ##.app-fixed-bar
    ##.client-guide-bar
    ##[class^="fixedDownload"]
    ##[class^="bottomApp"]
    ##[id^="fixedDownload"]
    ##[id^="appPromotion"]
    """
}
