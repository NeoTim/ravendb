﻿namespace Raven.Database.Storage.Voron.StorageActions
{
	using System.Linq;

	using Raven.Abstractions.Logging;
	using Raven.Abstractions.Util;

	using Voron;

	using System;
	using System.Collections.Generic;
	using System.IO;
	using System.Text;

	using Raven.Abstractions;
	using Raven.Abstractions.Data;
	using Raven.Abstractions.Exceptions;
	using Raven.Abstractions.MEF;
	using Raven.Database.Impl;
	using Raven.Database.Plugins;
	using Raven.Database.Storage.Voron.Impl;
	using Raven.Json.Linq;
	using Raven.Abstractions.Extensions;

	using global::Voron;
	using global::Voron.Impl;

	public class DocumentsStorageActions : IDocumentStorageActions
    {
        private readonly Table documentsTable;

        private readonly WriteBatch writeBatch;
        private readonly SnapshotReader snapshot;

        private readonly IUuidGenerator uuidGenerator;
        private readonly OrderedPartCollection<AbstractDocumentCodec> documentCodecs;
        private readonly IDocumentCacher documentCacher;

	    private static readonly ILog logger = LogManager.GetCurrentClassLogger();

        public DocumentsStorageActions(IUuidGenerator uuidGenerator,
            OrderedPartCollection<AbstractDocumentCodec> documentCodecs,
            IDocumentCacher documentCacher,
            WriteBatch writeBatch,
            SnapshotReader snapshot,
            Table documentsTable)
        {
            this.snapshot = snapshot;
            this.uuidGenerator = uuidGenerator;
            this.documentCodecs = documentCodecs;
            this.documentCacher = documentCacher;
            this.writeBatch = writeBatch;
            this.documentsTable = documentsTable;
        }

        public IEnumerable<JsonDocument> GetDocumentsByReverseUpdateOrder(int start, int take)
        {
            if (start < 0)
                throw new ArgumentException("must have zero or positive value", "start");
            if (take < 0)
                throw new ArgumentException("must have zero or positive value", "take");
            if (take == 0) yield break;

			using (var iter = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag)
										    .Iterate(snapshot,writeBatch))
			{
				int fetchedDocumentCount = 0;
                if(!iter.Seek(Slice.AfterAllKeys))
                    yield break;

				if(!iter.Skip(-start))
                    yield break;
				do
				{
					if (iter.CurrentKey == null || iter.CurrentKey.Equals(Slice.Empty))
						yield break;

					var key = GetKeyFromCurrent(iter);

					var document = DocumentByKey(key, null);
					if (document == null) //precaution - should never be true
					{
						throw new ApplicationException(String.Format("Possible data corruption - the key = '{0}' was found in the documents indice, but matching document was not found", key));
					}

					yield return document;

					fetchedDocumentCount++;
				} while (iter.MovePrev() && fetchedDocumentCount < take);
			}
        }

        public IEnumerable<JsonDocument> GetDocumentsAfter(Etag etag, int take, long? maxSize = null, Etag untilEtag = null)
        {
            if (take < 0)
                throw new ArgumentException("must have zero or positive value", "take");
            if(take == 0) yield break;

            if (String.IsNullOrEmpty(etag))
                throw new ArgumentNullException("etag");

			using (var iter = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag)
											.Iterate(snapshot,writeBatch))
			{
			    if (!iter.Seek(Slice.BeforeAllKeys))
			    {
			        yield break;
			    }

				long fetchedDocumentTotalSize = 0;
				int fetchedDocumentCount = 0;

				do
				{
					if (iter.CurrentKey == null || iter.CurrentKey.Equals(Slice.Empty))
						yield break;

					var docEtag = Etag.Parse(iter.CurrentKey.ToString());

					if (!EtagUtil.IsGreaterThan(docEtag, etag)) continue;

					if (untilEtag != null && fetchedDocumentCount > 0)
					{
						if (EtagUtil.IsGreaterThan(docEtag, untilEtag))
							yield break;
					}

					var key = GetKeyFromCurrent(iter);

					var document = DocumentByKey(key, null);
					if (document == null) //precaution - should never be true
					{
						throw new ApplicationException(String.Format("Possible data corruption - the key = '{0}' was found in the documents indice, but matching document was not found", key));
					}

					fetchedDocumentTotalSize += document.SerializedSizeOnDisk;
					fetchedDocumentCount++;

					if (maxSize.HasValue && fetchedDocumentTotalSize >= maxSize)
					{
						yield return document;
						yield break;
					}

					yield return document;
				} while (iter.MoveNext() && fetchedDocumentCount < take);
			}
        }

		private static string GetKeyFromCurrent(global::Voron.Trees.IIterator iter)
		{
			var key = String.Empty;
			using (var currentDataStream = iter.CreateStreamForCurrent())
			{
				var keyBytes = currentDataStream.ReadData();
                key = Encoding.UTF8.GetString(keyBytes);
			}
			return key;
		}

        public IEnumerable<JsonDocument> GetDocumentsWithIdStartingWith(string idPrefix, int start, int take)
        {
            if (String.IsNullOrEmpty(idPrefix))
                throw new ArgumentNullException("idPrefix");
            if (start < 0)
                throw new ArgumentException("must have zero or positive value", "start");
            if (take < 0)
                throw new ArgumentException("must have zero or positive value", "take");

			using (var iter = documentsTable.Iterate(snapshot,writeBatch))
			{
				iter.RequiredPrefix = idPrefix.ToLowerInvariant();
				if (take == 0 || iter.Seek(iter.RequiredPrefix) == false)
					yield break;

				var fetchedDocumentCount = 0;
				var alreadySkippedCount = 0; //we have to do it this way since we store in the same tree both data and metadata entries
				do
				{
					var dataKey = iter.CurrentKey.ToString();
                    if(dataKey.Contains(Util.MetadataSuffix)) continue;				    
					if (alreadySkippedCount++ < start) continue;

				    var originalKey = Util.OriginalKey(dataKey);
				    var fetchedDocument = DocumentByKey(originalKey, null);
				    if (fetchedDocument == null) continue;
				    
                    fetchedDocumentCount++;
				    yield return fetchedDocument;
				} while (iter.MoveNext() && fetchedDocumentCount < take);
			}
        }

        public long GetDocumentsCount()
        {
			using (var iter = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag)
										    .Iterate(snapshot,writeBatch))
			{
				long documentCount = 0;

			    if (!iter.Seek(Slice.BeforeAllKeys))
			    {
			        return 0;
			    }

				do
				{
					if (iter.CurrentKey != null && !iter.CurrentKey.Equals(Slice.Empty))
						++documentCount;
				} while (iter.MoveNext());

				return documentCount;
			}
        }

        public JsonDocument DocumentByKey(string key, TransactionInformation transactionInformation)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

            var lowerKey = key.ToLowerInvariant();
            var dataKey = Util.DataKey(lowerKey);
			var metadataKey = Util.MetadataKey(lowerKey);
            if (!documentsTable.Contains(snapshot, dataKey,writeBatch))
            {
                logger.Debug("Document with key='{0}' was not found",key);
                return null;
            }


            var metadataDocument = ReadDocumentMetadata(metadataKey);
            if (metadataDocument == null)
            {
                logger.Warn(String.Format("Metadata of document with key='{0} was not found, but the document itself exists.",key));
                return null;
            }

            var documentData = ReadDocumentData(dataKey, metadataDocument.Etag, metadataDocument.Metadata);

            logger.Debug("DocumentByKey() by key ='{0}'", key);

            var docSize = documentsTable.GetDataSize(snapshot, dataKey);
            var metadataSize = documentsTable.GetDataSize(snapshot, metadataKey);

            return new JsonDocument
            {
                DataAsJson = documentData,
                Etag = metadataDocument.Etag,
                Key = metadataDocument.Key, //original key - with user specified casing, etc.
                Metadata = metadataDocument.Metadata,
                SerializedSizeOnDisk = docSize + metadataSize,
                LastModified = metadataDocument.LastModified
            };
        }

        public JsonDocumentMetadata DocumentMetadataByKey(string key, TransactionInformation transactionInformation)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

            var lowerKey = key.ToLowerInvariant();
			var dataKey = Util.DataKey(lowerKey);
			var metadataKey = Util.MetadataKey(lowerKey);

            if (documentsTable.Contains(snapshot, dataKey,writeBatch))
                return ReadDocumentMetadata(metadataKey);

            logger.Debug("Document with key='{0}' was not found", key);
            return null;
        }

        public bool DeleteDocument(string key, Etag etag, out RavenJObject metadata, out Etag deletedETag)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

            var lowerKey = key.ToLowerInvariant();
			var dataKey = Util.DataKey(lowerKey);
			var metadataKey = Util.MetadataKey(lowerKey);

            if (!documentsTable.Contains(snapshot, dataKey,writeBatch))
            {
                logger.Debug("Document with key '{0}' was not found, and considered deleted", key);
                metadata = null;
                deletedETag = null;
                return false;
            }            

            if (!documentsTable.Contains(snapshot, metadataKey, writeBatch)) //data exists, but metadata is not --> precaution, should never be true
            {
                var errorString = String.Format("Document with key '{0}' was found, but its metadata wasn't found --> possible data corruption",key);
                throw new ApplicationException(errorString);
            }


            var existingEtag = EnsureDocumentEtagMatch(key, etag);
            var documentMetadata = ReadDocumentMetadata(metadataKey);
            metadata = documentMetadata.Metadata;

            deletedETag = etag != null ? existingEtag : documentMetadata.Etag;

            documentsTable.Delete(writeBatch, dataKey);
            documentsTable.Delete(writeBatch, metadataKey);

            documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag)
                          .Delete(writeBatch, deletedETag);

            documentCacher.RemoveCachedDocument(dataKey, etag);

            logger.Debug("Deleted document with key = '{0}'", key);

            return true;
        }

        public AddDocumentResult AddDocument(string key, Etag etag, RavenJObject data, RavenJObject metadata)
        {
            if(String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

            if (key != null && Encoding.UTF8.GetByteCount(key) >= UInt16.MaxValue)
                throw new ArgumentException(string.Format("The dataKey must be a maximum of {0} bytes in Unicode, key is: '{1}'", UInt16.MaxValue, key), "key");

            var lowerKey = key.ToLowerInvariant();
			var dataKey = Util.DataKey(lowerKey);

            Etag newEtag;

            DateTime savedAt;
            var isUpdate = WriteDocumentData(dataKey, key, etag, data, metadata, out newEtag, out savedAt);

            logger.Debug("AddDocument() - {0} document with key = '{1}'", isUpdate ? "Updated" : "Added", key);

            
            return new AddDocumentResult
            {
                Etag = newEtag,
                PrevEtag = etag,
                SavedAt = savedAt,
                Updated = isUpdate
            };            
        }	    

	    public AddDocumentResult PutDocumentMetadata(string key, RavenJObject metadata)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

			var metadataKey = Util.MetadataKey(key.ToLowerInvariant());
	        if (!documentsTable.Contains(snapshot, metadataKey,writeBatch))
            {
                throw new InvalidOperationException("Updating document metadata is only valid for existing documents, but " + key +
                                                                    " does not exists"); 
            }

            var newEtag = uuidGenerator.CreateSequentialUuid(UuidType.Documents);

            var savedAt = SystemTime.UtcNow;

            var isUpdated = PutDocumentMetadataInternal(key, metadata, newEtag, savedAt);

            logger.Debug("PutDocumentMetadata() - {0} document metadata with dataKey = '{1}'", isUpdated ? "Updated" : "Added", key);

            return new AddDocumentResult
            {
                SavedAt = savedAt,
                Etag = newEtag,
                Updated = isUpdated
            };
        }

	    private bool PutDocumentMetadataInternal(string key, RavenJObject metadata, Etag newEtag, DateTime savedAt)
	    {
	        return WriteDocumentMetadata(new JsonDocumentMetadata
	        {
	            Key = key,
	            Etag = newEtag,
	            Metadata = metadata,
	            LastModified = savedAt
	        });
	    }

	    public void IncrementDocumentCount(int value)
        {
            //nothing to do here
            //TODO : verify if this is the case - I might be missing something
        }

        public AddDocumentResult InsertDocument(string key, RavenJObject data, RavenJObject metadata, bool checkForUpdates)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

			if (!checkForUpdates && documentsTable.Contains(snapshot, Util.DataKey(key.ToLowerInvariant()),writeBatch))
            {
                throw new ApplicationException(String.Format("InsertDocument() - checkForUpdates is false and document with key = '{0}' already exists", key));
            }

            return AddDocument(key, null, data, metadata);
        }

        public void TouchDocument(string key, out Etag preTouchEtag, out Etag afterTouchEtag)
        {
            if (String.IsNullOrEmpty(key))
                throw new ArgumentNullException("key");

            var lowerKey = key.ToLowerInvariant();
			var dataKey = Util.DataKey(lowerKey);
			var metadataKey = Util.MetadataKey(lowerKey);

            if (!documentsTable.Contains(snapshot, dataKey, writeBatch))
            {
                logger.Debug("Document with dataKey='{0}' was not found", key);
                preTouchEtag = null;
                afterTouchEtag = null;
                return;
            }

            var metadata = ReadDocumentMetadata(metadataKey);

            var newEtag = uuidGenerator.CreateSequentialUuid(UuidType.Documents);
            afterTouchEtag = newEtag;
            preTouchEtag = metadata.Etag;
            metadata.Etag = newEtag;

            WriteDocumentMetadata(metadata);

            var keyByEtagDocumentIndice = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag);

            keyByEtagDocumentIndice.Delete(writeBatch,preTouchEtag);
            keyByEtagDocumentIndice.Add(writeBatch, newEtag, Encoding.UTF8.GetBytes(lowerKey));

            logger.Debug("TouchDocument() - document with key = '{0}'", key);
        }

        public Etag GetBestNextDocumentEtag(Etag etag)
        {
            if (etag == null) throw new ArgumentNullException("etag");

            using (var iter = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag)
                                            .Iterate(snapshot,writeBatch))
            {
                if (!iter.Seek(etag.ToString()) && 
                    !iter.Seek(Slice.BeforeAllKeys)) //if parameter etag not found, scan from beginning. if empty --> return original etag
                    return etag;

                do
                {
                    var docEtag = Etag.Parse(iter.CurrentKey.ToString());
                    if (EtagUtil.IsGreaterThan(docEtag, etag))
                        return docEtag;
                } while (iter.MoveNext());
            }

            return etag; //if not found, return the original etag
        }

        private Etag EnsureDocumentEtagMatch(string key, Etag etag)
        {
            if (etag == null)
                return null;

			var metadata = ReadDocumentMetadata(Util.MetadataKey(key.ToLowerInvariant()));

            if (metadata == null)
				return Etag.InvalidEtag;

            if (metadata.Etag != etag)
            {
                throw new ConcurrencyException(String.Format("Attempted to change document (key = {0}) with non-current etag (etag = {1})", key, etag));
            }

            return metadata.Etag;
        }

	    //returns true if it was update operation
        private bool WriteDocumentMetadata(JsonDocumentMetadata metadata)
        {
			var metadataStream = new MemoryStream(); //TODO : do not forget to change to BufferedPoolStream

			metadataStream.Write(metadata.Etag);
            metadataStream.Write(metadata.Key);
            
            if (metadata.LastModified.HasValue)
                metadataStream.Write(metadata.LastModified.Value.ToBinary());
            else
                metadataStream.Write((long)0);

			metadata.Metadata.WriteTo(metadataStream);

			metadataStream.Position = 0;

			var metadataKey = Util.MetadataKey(metadata.Key.ToLowerInvariant());
			documentsTable.Add(writeBatch, metadataKey, metadataStream);

			return documentsTable.Contains(snapshot, metadataKey, writeBatch);
        }

        private JsonDocumentMetadata ReadDocumentMetadata(string metadataKey)
        {
			using (var metadataReadResult = documentsTable.Read(snapshot, metadataKey, writeBatch))
			{
				if (metadataReadResult == null)
					return null;

				metadataReadResult.Stream.Position = 0;
				var etag = metadataReadResult.Stream.ReadEtag();
				var originalKey = metadataReadResult.Stream.ReadString();
			    var lastModifiedDateTimeBinary = metadataReadResult.Stream.ReadInt64();

                
				var existingCachedDocument = documentCacher.GetCachedDocument(metadataKey, etag);

				var metadata = existingCachedDocument != null ? existingCachedDocument.Metadata : metadataReadResult.Stream.ToJObject();
			    var lastModified = lastModifiedDateTimeBinary > 0 ? DateTime.FromBinary(lastModifiedDateTimeBinary) : (DateTime?)null;

				return new JsonDocumentMetadata
				{
					Key = originalKey, 
					Etag = etag,
					Metadata = metadata,
                    LastModified = lastModified
				};
			}
        }

        private bool WriteDocumentData(string dataKey, string originalKey, Etag etag, RavenJObject data, RavenJObject metadata, out Etag newEtag, out DateTime savedAt)
        {
            var isUpdate = documentsTable.Contains(snapshot, dataKey, writeBatch);

            if (isUpdate)
            {
                EnsureDocumentEtagMatch(originalKey, etag);           
            }
            else if (etag != null && etag != Etag.Empty)
            {
                throw new ConcurrencyException(String.Format("Attempted to write document with non-current etag (key = {0})", dataKey));
            }

            Stream dataStream = new MemoryStream(); //TODO : do not forget to change to BufferedPoolStream            
            data.WriteTo(dataStream);

            var finalDataStream = documentCodecs.Aggregate(dataStream,
                (current, codec) => codec.Encode(dataKey, data, metadata, current));

            finalDataStream.Position = 0;
            documentsTable.Add(writeBatch, dataKey, finalDataStream);

            newEtag = uuidGenerator.CreateSequentialUuid(UuidType.Documents);
            savedAt = SystemTime.UtcNow;

            var isUpdated = PutDocumentMetadataInternal(originalKey, metadata, newEtag, savedAt);

            var keyByEtagDocumentIndice = documentsTable.GetIndex(Tables.Documents.Indices.KeyByEtag);
            keyByEtagDocumentIndice.Add(writeBatch, newEtag, Encoding.UTF8.GetBytes(originalKey));

            return isUpdated;
        }
        
        private RavenJObject ReadDocumentData(string dataKey, Etag existingEtag, RavenJObject metadata)
	    {
	        var existingCachedDocument = documentCacher.GetCachedDocument(dataKey, existingEtag);
	        if (existingCachedDocument != null)
	            return existingCachedDocument.Document;

	        using (var documentReadResult = documentsTable.Read(snapshot, dataKey, writeBatch))
	        {
	            if (documentReadResult == null) //non existing document
	                return null;

                var decodedDocumentStream = documentCodecs.Aggregate(documentReadResult.Stream,
                            (current, codec) => codec.Value.Decode(dataKey, metadata, documentReadResult.Stream));

                var documentData = decodedDocumentStream.ToJObject();

                documentCacher.SetCachedDocument(dataKey, existingEtag, documentData, metadata, (int)documentReadResult.Stream.Length);

	            return documentData;
	        }
	    }
    }
}
