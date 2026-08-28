package org.cadview.cad_view

import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import com.google.ads.mediation.admob.AdMobAdapter
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import java.util.Collections

class MainActivity : CadViewActivityBase() {
    private val banners = Collections.synchronizedSet(mutableSetOf<StoreBannerView>())
    @Volatile private var personalized = false
    @Volatile private var initialized = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "org.cadview/global_store_banner",
            StoreBannerFactory(
                activity = this,
                bannerId = BuildConfig.CADVIEW_ADMOB_BANNER_ID,
                personalized = { personalized },
                onCreate = { banners.add(it) },
                onDispose = { banners.remove(it) },
            ),
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.cadview/store_ads",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(true)
                "initialize" -> {
                    personalized = call.argument<Boolean>("personalized") == true
                    requestConsentAndInitialize(result)
                }
                "setPersonalization" -> {
                    personalized = call.argument<Boolean>("personalized") == true
                    result.success(null)
                }
                "privacyOptions" -> {
                    UserMessagingPlatform.showPrivacyOptionsForm(this) { error ->
                        if (error == null) result.success(null)
                        else result.error("ump_privacy_options", error.message, error.errorCode)
                    }
                }
                "suspend" -> {
                    synchronized(banners) { banners.toList().forEach(StoreBannerView::dispose) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestConsentAndInitialize(result: MethodChannel.Result) {
        if (initialized) {
            result.success(null)
            return
        }
        val parameters = ConsentRequestParameters.Builder()
            .setTagForUnderAgeOfConsent(false)
            .build()
        val consent = UserMessagingPlatform.getConsentInformation(this)
        consent.requestConsentInfoUpdate(
            this,
            parameters,
            {
                UserMessagingPlatform.loadAndShowConsentFormIfRequired(this) { formError ->
                    if (formError != null) {
                        result.error("ump_form", formError.message, formError.errorCode)
                        return@loadAndShowConsentFormIfRequired
                    }
                    MobileAds.initialize(this) {
                        initialized = true
                        result.success(null)
                    }
                }
            },
            { error -> result.error("ump_update", error.message, error.errorCode) },
        )
    }
}

private class StoreBannerFactory(
    private val activity: MainActivity,
    private val bannerId: String,
    private val personalized: () -> Boolean,
    private val onCreate: (StoreBannerView) -> Unit,
    private val onDispose: (StoreBannerView) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        StoreBannerView(context, bannerId, personalized(), onCreate, onDispose)
}

private class StoreBannerView(
    context: Context,
    bannerId: String,
    personalized: Boolean,
    private val onCreate: (StoreBannerView) -> Unit,
    private val onDispose: (StoreBannerView) -> Unit,
) : PlatformView {
    private val container = FrameLayout(context)
    private var adView: AdView? = AdView(context)
    private var disposed = false

    init {
        onCreate(this)
        val banner = requireNotNull(adView)
        banner.adUnitId = bannerId
        banner.setAdSize(AdSize.BANNER)
        banner.adListener = object : AdListener() {
            override fun onAdFailedToLoad(error: LoadAdError) {
                container.visibility = View.GONE
            }

            override fun onAdLoaded() {
                container.visibility = View.VISIBLE
                // Pause after the first response: CADView intentionally uses a
                // one-shot home placement and never refreshes in the viewer.
                banner.pause()
            }
        }
        container.visibility = View.GONE
        container.addView(banner)
        val extras = Bundle()
        if (!personalized) extras.putString("npa", "1")
        val request = AdRequest.Builder()
            .addNetworkExtrasBundle(AdMobAdapter::class.java, extras)
            .build()
        banner.loadAd(request)
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        adView?.destroy()
        adView = null
        container.removeAllViews()
        container.visibility = View.GONE
        onDispose(this)
    }
}
