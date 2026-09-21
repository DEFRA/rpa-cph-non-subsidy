namespace RPA.CPH.NonSubsidy.Domain.Migrations
{
    using System;
    using System.Data.Entity.Migrations;
    
    public partial class SBIIndex : DbMigration
    {
        public override void Up()
        {
            CreateIndex("CPH.Customers", "SBI", unique: true);
        }
        
        public override void Down()
        {
            DropIndex("CPH.Customers", new[] { "SBI" });
        }
    }
}
