namespace RPA.CPH.NonSubsidy.Domain.Migrations
{
    using System;
    using System.Data.Entity.Migrations;
    
    public partial class InitialCreate : DbMigration
    {
        public override void Up()
        {
            CreateTable(
                "CPH.Addresses",
                c => new
                    {
                        AddressId = c.Int(nullable: false, identity: true),
                        CustomerId = c.Int(nullable: false),
                        Address1 = c.String(nullable: false),
                        Address2 = c.String(),
                        Address3 = c.String(),
                        Address4 = c.String(),
                        Address5 = c.String(),
                        PostCode = c.String(nullable: false),
                    })
                .PrimaryKey(t => t.AddressId)
                .ForeignKey("CPH.Customers", t => t.CustomerId, cascadeDelete: true)
                .Index(t => t.CustomerId);
            
            CreateTable(
                "CPH.Customers",
                c => new
                    {
                        CustomerId = c.Int(nullable: false, identity: true),
                        SBI = c.Int(nullable: false),
                        BusinessName = c.String(nullable: false),
                    })
                .PrimaryKey(t => t.CustomerId);
            
            CreateTable(
                "Audit.Audit",
                c => new
                    {
                        CustomerId = c.Int(nullable: false),
                        LastUpdatedBy = c.String(),
                        LastUpdated = c.DateTime(nullable: false),
                    })
                .PrimaryKey(t => t.CustomerId)
                .ForeignKey("CPH.Customers", t => t.CustomerId, cascadeDelete: true)
                .Index(t => t.CustomerId);
            
            CreateTable(
                "CPH.Cases",
                c => new
                    {
                        CustomerId = c.Int(nullable: false),
                        CRMCaseReferenceNumber = c.String(nullable: false),
                    })
                .PrimaryKey(t => t.CustomerId)
                .ForeignKey("CPH.Customers", t => t.CustomerId, cascadeDelete: true)
                .Index(t => t.CustomerId);
            
            CreateTable(
                "CPH.Land",
                c => new
                    {
                        LandId = c.Int(nullable: false, identity: true),
                        CustomerId = c.Int(nullable: false),
                        County = c.Int(nullable: false),
                        Parish = c.Int(nullable: false),
                        Holding = c.Int(nullable: false),
                    })
                .PrimaryKey(t => t.LandId)
                .ForeignKey("CPH.Customers", t => t.CustomerId, cascadeDelete: true)
                .Index(t => t.CustomerId);
            
            CreateTable(
                "CPH.LandParcels",
                c => new
                    {
                        LandParcelId = c.Int(nullable: false, identity: true),
                        LandId = c.Int(nullable: false),
                        GridReference = c.String(),
                        PlaceOfBusiness = c.Boolean(nullable: false),
                    })
                .PrimaryKey(t => t.LandParcelId)
                .ForeignKey("CPH.Land", t => t.LandId, cascadeDelete: true)
                .Index(t => t.LandId);
            
        }
        
        public override void Down()
        {
            DropForeignKey("CPH.LandParcels", "LandId", "CPH.Land");
            DropForeignKey("CPH.Land", "CustomerId", "CPH.Customers");
            DropForeignKey("CPH.Cases", "CustomerId", "CPH.Customers");
            DropForeignKey("Audit.Audit", "CustomerId", "CPH.Customers");
            DropForeignKey("CPH.Addresses", "CustomerId", "CPH.Customers");
            DropIndex("CPH.LandParcels", new[] { "LandId" });
            DropIndex("CPH.Land", new[] { "CustomerId" });
            DropIndex("CPH.Cases", new[] { "CustomerId" });
            DropIndex("Audit.Audit", new[] { "CustomerId" });
            DropIndex("CPH.Addresses", new[] { "CustomerId" });
            DropTable("CPH.LandParcels");
            DropTable("CPH.Land");
            DropTable("CPH.Cases");
            DropTable("Audit.Audit");
            DropTable("CPH.Customers");
            DropTable("CPH.Addresses");
        }
    }
}
