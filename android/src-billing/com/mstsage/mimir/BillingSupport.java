package com.mstsage.mimir;

import android.app.Activity;
import android.util.Log;

import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Play Billing tip jar: consumable one-time products, consumed right after purchase. */
public final class BillingSupport implements Support {
    private static final String TAG = "MimirBilling";
    static final String[] PRODUCTS = { "tip_small", "tip_medium", "tip_large" };

    private BillingClient client;
    private RubyRuntime ruby;
    private final Map<String, ProductDetails> details = new HashMap<>();
    private boolean connecting = false;

    @Override
    public void connect(Activity activity, RubyRuntime ruby) {
        this.ruby = ruby;
        if (client != null) return;
        client = BillingClient.newBuilder(activity.getApplicationContext())
                .setListener((result, purchases) -> {
                    if (result.getResponseCode() == BillingClient.BillingResponseCode.OK && purchases != null) {
                        for (Purchase p : purchases) handlePurchase(p);
                    } else if (result.getResponseCode() == BillingClient.BillingResponseCode.USER_CANCELED) {
                        ruby.event("billing.cancelled");
                    } else {
                        ruby.event("billing.error", "text", result.getDebugMessage() + " (" + result.getResponseCode() + ")");
                    }
                })
                .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
                .build();
        start();
    }

    private void start() {
        if (connecting || client == null) return;
        connecting = true;
        client.startConnection(new BillingClientStateListener() {
            @Override public void onBillingSetupFinished(BillingResult r) {
                connecting = false;
                if (r.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                    query();
                    // consume anything left over from an interrupted flow
                    client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build(),
                            (res, list) -> { if (list != null) for (Purchase p : list) handlePurchase(p); });
                } else {
                    ruby.event("billing.unavailable", "reason", r.getDebugMessage() + " (" + r.getResponseCode() + ")");
                }
            }
            @Override public void onBillingServiceDisconnected() { connecting = false; }
        });
    }

    @Override
    public void query() {
        if (client == null || !client.isReady()) { start(); return; }
        List<QueryProductDetailsParams.Product> list = new ArrayList<>();
        for (String id : PRODUCTS) {
            list.add(QueryProductDetailsParams.Product.newBuilder().setProductId(id).setProductType(BillingClient.ProductType.INAPP).build());
        }
        client.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(list).build(), (result, qr) -> {
            if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                ruby.event("billing.unavailable", "reason", result.getDebugMessage() + " (" + result.getResponseCode() + ")");
                return;
            }
            JSONArray arr = new JSONArray();
            details.clear();
            for (ProductDetails d : qr.getProductDetailsList()) {
                details.put(d.getProductId(), d);
                ProductDetails.OneTimePurchaseOfferDetails o = d.getOneTimePurchaseOfferDetails();
                try {
                    JSONObject j = new JSONObject();
                    j.put("id", d.getProductId());
                    j.put("title", d.getName());
                    j.put("description", d.getDescription());
                    j.put("price", o != null ? o.getFormattedPrice() : "");
                    arr.put(j);
                } catch (Exception ignored) {}
            }
            ruby.event("billing.ready", "products", arr);
        });
    }

    @Override
    public void buy(Activity activity, String productId) {
        ProductDetails d = details.get(productId);
        if (d == null) { ruby.event("billing.error", "text", "Unknown product " + productId); query(); return; }
        List<BillingFlowParams.ProductDetailsParams> params = new ArrayList<>();
        params.add(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(d).build());
        BillingResult r = client.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(params).build());
        if (r.getResponseCode() != BillingClient.BillingResponseCode.OK) ruby.event("billing.error", "text", r.getDebugMessage());
    }

    private void handlePurchase(Purchase p) {
        if (p.getPurchaseState() != Purchase.PurchaseState.PURCHASED) return;
        client.consumeAsync(ConsumeParams.newBuilder().setPurchaseToken(p.getPurchaseToken()).build(), (r, token) -> {
            if (r.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                for (String id : p.getProducts()) ruby.event("billing.purchased", "product", id);
            } else {
                Log.w(TAG, "consume failed: " + r.getDebugMessage());
                ruby.event("billing.error", "text", "Thank you! (consume failed: " + r.getDebugMessage() + ")");
            }
        });
    }

    @Override
    public void destroy() {
        if (client != null) { client.endConnection(); client = null; }
    }
}
