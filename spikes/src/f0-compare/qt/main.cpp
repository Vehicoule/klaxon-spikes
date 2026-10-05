// f0-qt : comparatif QPainter (raster CPU) — sous-ensemble fidèle du corpus KX-SPEC.
// Usage: f0-qt <outdir>  → f0-qt.json + f0-qt.png
#include <QApplication>
#include <QPainter>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFile>
#include <QDir>
#include <QElapsedTimer>
#include <QTextDocument>
#include <QGraphicsBlurEffect>
#include <QGraphicsScene>
#include <QGraphicsPixmapItem>
#include <cstdio>
#include <cmath>

static const int W = 800, H = 600;

static void s1(QPainter& p){ // vectoriel : 200 formes translucides
    p.fillRect(0,0,W,H,Qt::white);
    for(int i=0;i<200;i++){ p.setBrush(QColor((i*37)%256,(i*91)%256,(i*57)%256,140));
        p.setPen(Qt::NoPen);
        if(i%3==0) p.drawRect((i*13)%(W-60),(i*29)%(H-40),60,40);
        else if(i%3==1) p.drawEllipse((i*17)%(W-50),(i*31)%(H-50),50,50);
        else p.drawRoundedRect((i*11)%(W-70),(i*23)%(H-30),70,30,8,8);
    }
}
static void s2(QPainter& p){ // paragraphes + styles
    p.fillRect(0,0,W,H,Qt::white);
    QTextDocument d; d.setTextWidth(560); d.setHtml(
        "<p style='font-size:20px'>Titre — évaluation <b>Klaxon f0</b> bench §éçà€</p>"
        "<p style='font-size:14px;color:#345'>The quick brown fox jumps over the lazy dog. "
        "Répété pour former un paragraphe complet avec styles mixtes <i>italique</i>, "
        "<b>gras</b> et retours à la ligne sur une largeur contrainte de 560px.</p>"
        "<p style='font-size:12px'>0123456789 — second paragraphe de corps de texte.</p>");
    d.drawContents(&p, QRectF(40,40,560,400));
}
static void s3(QPainter& p){ // blur : 8 ellipses floutées (QGraphicsBlurEffect)
    QImage layer(W,H,QImage::Format_ARGB32); layer.fill(Qt::white); QPainter lp(&layer);
    for(int i=0;i<8;i++){ lp.setBrush(QColor(30*i,80+i*15,220,220)); lp.setPen(Qt::NoPen);
        lp.drawEllipse(40+i*90,120+i*45,140,140); } lp.end();
    QGraphicsScene sc; QGraphicsPixmapItem* it = sc.addPixmap(QPixmap::fromImage(layer));
    QGraphicsBlurEffect fx; fx.setBlurRadius(16); it->setGraphicsEffect(&fx);
    sc.setSceneRect(0,0,W,H); sc.render(&p, QRectF(0,0,W,H));
}
static void s4(QPainter& p){ // images décodées ×50
    p.fillRect(0,0,W,H,Qt::white); QImage f("fixture.png");
    for(int i=0;i<50;i++) p.drawImage((i*67)%(W-120),(i*43)%(H-120), f.scaled(120,120));
}
static void s6(QPainter& p){ // 100 paths bézier
    p.fillRect(0,0,W,H,Qt::white); p.setPen(QPen(QColor(20,40,160,200),2)); p.setBrush(Qt::NoBrush);
    for(int i=0;i<100;i++){ QPainterPath q(QPointF((i*7)%W, H-60));
        q.cubicTo(QPointF(60+i*5,80+i*2), QPointF(320-i,40+i*4), QPointF(700,(300+i*6)%(H-20)));
        p.drawPath(q); }
}
static void s8(QPainter& p){ // composite : clip + transform + layers
    p.fillRect(0,0,W,H,Qt::white);
    for(int i=0;i<10;i++){ p.save(); p.setClipRect(60+i*40,60+i*30,400-i*20,260-i*12);
        p.translate(20+i*10,10+i*8); p.rotate(3+i);
        p.fillRect(0,0,500,320,QColor(40+i*20,180-i*10,120,110)); p.restore(); }
    for(int i=0;i<20;i++){ p.setOpacity(0.6); p.drawEllipse(i*30,i*22,80,80); }
}

int main(int argc, char** argv){
    QApplication app(argc, argv);
    QString out = argc>1? argv[1] : "out"; QDir().mkpath(out);
    // fixture
    if(!QFile::exists("fixture.png")){ QImage f(256,256,QImage::Format_ARGB32);
        QPainter fp(&f); fp.fillRect(0,0,256,256,QColor(80,160,240));
        fp.fillRect(20,20,100,100,Qt::red); fp.setPen(QPen(Qt::black,3));
        fp.drawEllipse(120,120,100,100); fp.drawText(10,200,"fix 256"); f.save("fixture.png"); }
    const char* names[] = {"s1","s2","s3","s4","s6","s8"};
    void (*fns[])(QPainter&) = {s1,s2,s3,s4,s6,s8};
    QJsonObject root; root["tool"]="qt5-qpainter"; root["backend"]="raster(qimage-cpu)"; root["driver"]="qt-raster";
    QJsonArray scenes;
    for(int s=0;s<6;s++){
        QImage img(W,H,QImage::Format_ARGB32); double first=-1, rec=0;
        for(int it=0;it<50;it++){ QElapsedTimer t; t.start();
            img.fill(0); QPainter p(&img); fns[s](p); p.end();
            double ms = t.nsecsElapsed()/1e6; if(first<0) first=ms; rec += ms; }
        qint64 nw=0;
        for(int y=0;y<H;y+=7) for(int x=0;x<W;x+=7)
            if(img.pixel(x,y)!=0xffffffff) nw++;
        QJsonObject o; o["id"]=names[s]; o["record_ms"]=rec/50; o["first_ms"]=first;
        o["nw"]=nw; o["status"]= nw>0?"PASS":"FAIL";
        scenes.append(o);
        printf("%s rec=%.2f first=%.2f nw=%lld %s\n", names[s], rec/50, first, (long long)nw, nw>0?"PASS":"FAIL");
    }
    root["scenes"]=scenes;
    QFile fj(out+"/f0-qt.json"); fj.open(QIODevice::WriteOnly); fj.write(QJsonDocument(root).toJson());
    QImage shot(W,H,QImage::Format_ARGB32); QPainter sp(&shot); s1(sp); sp.end(); shot.save(out+"/f0-qt.png");
    return 0;
}
